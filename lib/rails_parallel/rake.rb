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
    SHARD_PATTERN = /shard_(\d+)$/.freeze

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

      @pid = fork do
        my_socket.close
        ENV['RAILS_PARALLEL_ROOT'] = Rails.root.to_s
        script = Pathname.new(__FILE__).dirname.dirname.dirname + 'bin/rails_parallel_worker'
        exec(script.to_s, sock.fileno.to_s, sock => sock)
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
    def load_shard_names
      @shard_names ||= YAML.load(ERB.new(File.read("config/database.yml")).result)['test'].keys.grep(SHARD_PATTERN).each_with_object([]) do |s, names|
        names[s.match(SHARD_PATTERN)[1].to_i] = s
      end
    end

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
      dbconfig = Rails.application.config.database_configuration["test"]
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
      load_shard_names

      digest   = schema_digest

      if cached_schema_exists?(digest)
        puts "RP: Using cached schema"
        schema_path_hash = path_hash_for(digest)
      else
        puts 'RP: Building new schema ... '

        schema_path_hash = silently { generate_schema(digest) }

        puts "RP: Generated new schema"
      end
      schema_path_hash
    end

    def cached_schema_exists?(digest)
      @shard_names.map do |shard|
        shard.nil? ? "#{SCHEMA_DIR}/#{digest}.sql" : "#{SCHEMA_DIR}/#{shard}_#{digest}.sql"
      end.all? {|s| File.exists?(s)}
    end

    def path_hash_for(digest)
      Hash[@shard_names.map {|d| d.nil? ? ["master", "#{SCHEMA_DIR}/#{digest}.sql"] : [d, "#{SCHEMA_DIR}/#{d}_#{digest}.sql"] }]
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

    def make_config_use_scratch_database(config)
      config = config.with_indifferent_access
      scratch = {}.with_indifferent_access
      config.keys.each do |key|
        if 'database' == key
          scratch[key] = config[key] + '_rp_scratch'
        end
        if %w(adapter host encoding port username password).include?(key)
          scratch[key] = config[key]
        end
        if SHARD_PATTERN =~ key
          m = scratch[key] = config[key]
          m[:database] += '_rp_scratch'
        end
      end
      scratch
    end

    def drop_database(config)
      puts "RP: dropping.. #{config[:database]}"
      ActiveRecord::Base.connection.drop_database(config[:database])
    rescue
      puts "#{config[:database]} not exists"
    end

    def drop_all(config)
      drop_database(config)
      config.each_value do |sub_config|
        drop_database(sub_config) if sub_config.is_a?(Hash) && sub_config[:database]
      end
    end

    def generate_schema(digest)
      invoke_task('environment')
      # This guy is here because db:load_config is a dependency
      # of db:create, as we change the config in a few lines bellow
      # running db:create would clobber the config changes.
      invoke_task('db:load_config')

      config = ActiveRecord::Base.configurations[Rails.env].deep_dup
      scratch = make_config_use_scratch_database(config)
      ActiveRecord::Base.configurations[Rails.env] = scratch

      # Workaround for Rails 3.2 insisting on dropping the test DB when we db:drop.
      # The runner process may die because the test DB is gone.
      old_test_config = ActiveRecord::Base.configurations['test']
      ActiveRecord::Base.configurations['test'] = nil

      drop_all(scratch)
      invoke_task('db:create')
      invoke_task('parallel:db:setup')

      schema_path_hash = {}
      FileUtils.mkdir_p(SCHEMA_DIR)
      @shard_names.each do |shard|

        shard_config = shard.nil? ? scratch : scratch[shard]
        schema = shard.nil? ? "#{SCHEMA_DIR}/#{digest}.sql" : "#{SCHEMA_DIR}/#{shard}_#{digest}.sql"
        schema_path_hash[shard.nil? ? "master" : shard] = schema

        Tempfile.open(["#{digest}.", ".sql"], SCHEMA_DIR) do |file|
          command = ['mysqldump', '--no-data']
          command << "--host=#{shard_config[:host]}"         unless shard_config[:host].blank?
          command << "--user=#{shard_config[:username]}"     unless shard_config[:username].blank?
          command += "--password=#{shard_config[:password]}" unless shard_config[:password].blank?
          command << shard_config[:database]

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
        end
      end

      drop_all(scratch)

      ActiveRecord::Base.configurations[Rails.env] = config
      ActiveRecord::Base.configurations['test'] = old_test_config
      ActiveRecord::Base.establish_connection(config)
      schema_path_hash
    end

    def invoke_task(name)
      task = ::Rake::Task[name]
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
