require 'rake/testtask'
require 'fcntl'
require 'pathname'

require 'rails_parallel/object_socket'
require 'rails_parallel/schema'

module RailsParallel
  class Rake
    class UnexpectedResponse < StandardError
      attr_reader :expected, :received

      def initialize(expected, received)
        @expected = expected
        @received = received
      end

      def to_s
        "Expected #{@expected}, got #{received}"
      end
    end

    class SuiteFailure < StandardError; end

    include Singleton
    include ::Rake::DSL

    SCHEMA_DIR = 'tmp/rails_parallel/schema'

    mattr_accessor :schema_files
    @@schema_files = ['db/schema.rb']

    def self.launch
      instance.launch
    end

    def self.run(name, ruby_opts, files)
      instance.launch
      instance.run(name, ruby_opts, files)
    end

    def self.load_current_db
      instance.load_schema
    end

    def launch
      return if @pid
      at_exit { shutdown }

      create_test_db

      my_socket, c_socket = ObjectSocket.pair
      sock = c_socket.socket
      sock.fcntl(Fcntl::F_SETFD, sock.fcntl(Fcntl::F_GETFD, 0) & ~Fcntl::FD_CLOEXEC)

      @pid = fork do
        my_socket.close
        ENV['RAILS_PARALLEL_ROOT'] = Rails.root.to_s
        script = Pathname.new(__FILE__).dirname.dirname.dirname + 'bin/rails_parallel_worker'
        exec(script.to_s, sock.fileno.to_s)
        raise 'exec failed'
      end

      c_socket.close
      @socket = my_socket

      begin
        @socket.each_object do |obj|
          case obj
          when :starting
            @socket << schema_file
          when :started
            break
          end
        end
      rescue Exception
        shutdown
        raise
      end
    end

    def run(name, ruby_opts, files)
      expect(:ready)

      @socket << {
        :name    => name,
        :options => parse_options(ruby_opts),
        :files   => files.to_a
      }

      begin
        expect(:success)
      rescue UnexpectedResponse => e
        raise SuiteFailure.new("Test suite '#{name}' failed") if e.received == :failure
        raise e
      end
    end

    def shutdown
      if @pid
        @socket << :shutdown
        Process.waitpid(@pid)
        @pid = nil
      end
    end

    def load_schema
      Schema.new(schema_file).load_main_db
      puts "RP: Loaded #{Rails.env} schema."
    end

    private

    def expect(want)
      got = @socket.next_object
      raise UnexpectedResponse.new(want, got) unless want == got
    end

    def parse_options(ruby_opts)
      ruby_opts.flatten.collect do |opt|
        case opt
        when /^-r/
          [:require, $']
        else
          raise "Unhandled Ruby option: #{opt.inspect}"
        end
      end
    end

    def create_test_db
      dbconfig = YAML.load_file('config/database.yml')['test']
      ActiveRecord::Base.establish_connection(dbconfig.merge('database' => nil))
      begin
        ActiveRecord::Base.connection.create_database(dbconfig['database'])
      rescue ActiveRecord::StatementInvalid
        # database exists
      end
    end

    def get_schema_files
      return @@schema_files.call if @@schema_files.kind_of?(Proc)
      @@schema_files
    end

    def schema_digest
      files = FileList[*get_schema_files].sort
      digest = Digest::MD5.new
      files.each { |f| digest.update("#{f}|#{File.read(f)}|") }
      digest.hexdigest
    end

    def schema_file
      @schema_file ||= make_schema_file
    end

    def make_schema_file
      digest   = schema_digest
      basename = "#{digest}.sql"
      schema   = "#{SCHEMA_DIR}/#{basename}"

      if File.exist? schema
        puts "RP: Using cached schema: #{basename}"
      else
        puts 'RP: Building new schema ... '

        silently { generate_schema(digest, schema) }

        puts "RP: Generated new schema: #{basename}"
      end

      schema
    end

    def silently
      return yield if ::Rake.application.options.trace

      [$stdout, $stderr].each(&:flush)
      old_stdout, old_stderr = $stdout, $stderr

      Tempfile.open('rp-silently') do |fh|
        fh.unlink
        begin
          $stdout = $stderr = fh
          yield
        rescue StandardError => e
          fh.seek(0, IO::SEEK_SET)
          old_stdout.puts fh.read
          raise e
        ensure
          $stdout = old_stdout
          $stderr = old_stderr
        end
      end
    end

    def generate_schema(digest, schema)
      FileUtils.mkdir_p(SCHEMA_DIR)
      Tempfile.open(["#{digest}.", ".sql"], SCHEMA_DIR) do |file|
        invoke_task('db:create', :force)
        invoke_task('environment')

        config  = ActiveRecord::Base.configurations[Rails.env].with_indifferent_access
        scratch = config.merge(:database => config[:database] + '_rp_scratch')

        ActiveRecord::Base.configurations[Rails.env] = scratch
        invoke_task('db:drop', :force)
        invoke_task('db:create', :force)
        invoke_task('parallel:db:setup', :force)

        command = ['mysqldump', '--no-data']
        command << "--host=#{scratch[:host]}"         unless scratch[:host].blank?
        command << "--user=#{scratch[:username]}"     unless scratch[:username].blank?
        command += "--password=#{scratch[:password]}" unless scratch[:password].blank?
        command << scratch[:database]

        pid = fork do
          STDOUT.reopen(file)
          exec *command
          raise 'exec failed'
        end

        Process.wait(pid)
        raise 'mysqldump failed' unless $?.success?
        raise 'No schema dumped' unless file.size > 0

        check_schema(file)

        file.close
        File.rename(file.path, schema)

        invoke_task('db:drop', :force)

        ActiveRecord::Base.configurations[Rails.env] = config
        ActiveRecord::Base.establish_connection(config)
      end
    end

    def invoke_task(name, force = false)
      task = ::Rake::Task[name]
      task.reenable if force
      task.invoke
    end

    def check_schema(fh)
      fh.seek(0, IO::SEEK_SET)
      schema = fh.read

      raise "No schema_migrations table found in dump" unless schema.include?("CREATE TABLE `schema_migrations`")
      raise "Dump appears to be incomplete" unless schema.include?("\n-- Dump completed on ")
    end
  end
end

module Rake
  class TestTask
    @@patched = false

    def initialize(name=:test)
      if name.kind_of? Hash
        @name    = name.keys.first
        @depends = name.values.first
      else
        @name    = name
        @depends = []
      end
      @full_name = [Rake.application.current_scope, @name].join(':')

      @libs = ["lib"]
      @pattern = nil
      @options = nil
      @test_files = nil
      @verbose = false
      @warning = false
      @loader = :rake
      @ruby_opts = []
      yield self if block_given?
      @pattern = 'test/test*.rb' if @pattern.nil? && @test_files.nil?

      if !@@patched && self.class.name == 'TestTaskWithoutDescription'
        TestTaskWithoutDescription.class_eval { def define; super(false); end }
        @@patched = true
      end

      define
    end

    def define(describe = true)
      lib_path = @libs.join(File::PATH_SEPARATOR)
      desc "Run tests" + (@full_name == :test ? "" : " for #{@name}") if describe
      task @name => @depends do
        files = file_list.map {|f| f =~ /[\*\?\[\]]/ ? FileList[f] : f }.flatten(1)
        RailsParallel::Rake.run(@full_name, ruby_opts, files)
      end
      self
    end
  end
end
