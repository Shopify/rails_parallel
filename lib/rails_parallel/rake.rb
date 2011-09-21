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

    SCHEMA_DIR = 'tmp/rails_parallel/schema'

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
        ENV['RAILS_PARALLEL_ROOT'] = Rails.root
        script = Pathname.new(__FILE__).dirname.dirname.dirname + 'bin/rails_parallel_worker'
        exec(script.to_s, sock.fileno.to_s)
        raise 'exec failed'
      end

      c_socket.close
      @socket = my_socket

      expect(:started)
    end

    def run(name, ruby_opts, files)
      options = parse_options(ruby_opts)
      schema  = schema_file

      case @socket.next_object
      when :schema_needed
        @socket << schema
        expect(:started)
        expect(:ready)
      when :ready
        # success
      end

      @socket << {
        :name    => name,
        :schema  => schema,
        :options => options,
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
      ActiveRecord::Base.connection.execute("CREATE DATABASE IF NOT EXISTS #{dbconfig['database']}")
    end

    def schema_digest
      files = FileList['db/schema.versioned.rb', 'db/migrate/*.rb'].sort
      digest = Digest::MD5.new
      files.each { |f| digest.update("#{f}|#{File.read(f)}|") }
      digest.hexdigest
    end

    def schema_file
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
      File.open('/dev/null', 'w') do |fh|
        $stdout = $stderr = fh
        yield
      end
    ensure
      $stdout = STDOUT
      $stderr = STDERR
    end

    def generate_schema(digest, schema)
      FileUtils.mkdir_p(SCHEMA_DIR)
      Tempfile.open(["#{digest}.", ".sql"], SCHEMA_DIR) do |file|
        ::Rake::Task['parallel:db:setup'].invoke
        sh "mysqldump --no-data -u root shopify_dev > #{file.path}"

        raise 'No schema dumped' unless file.size > 0
        File.rename(file.path, schema)
        $schema_dump_file = nil
      end
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
