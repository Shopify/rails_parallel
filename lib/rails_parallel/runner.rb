require 'rails_parallel/runner/parent'
require 'rails_parallel/object_socket'

module RailsParallel
  class Runner
    class Shutdown < StandardError; end

    def self.launch(socket, script)
      Runner.new(socket, script).run
    end

    @@before_fork = []
    @@after_fork = []
    @@before_exit = []

    def self.before_fork(&block)
      @@before_fork << block
    end

    def self.after_fork(&block)
      @@after_fork << block
    end

    def self.before_exit(&block)
      @@before_exit << block
    end

    def self.run_before_fork
      @@before_fork.each { |p| p.call }
    end

    def self.run_after_fork(worker_num)
      @@after_fork.each { |p| p.call(worker_num) }
    end

    def self.run_before_exit(worker_num)
      @@before_exit.each { |p| p.call(worker_num) }
    end

    def initialize(socket, script)
      @socket = socket
      @script = script
    end

    def run
      prepare

      puts 'RP: Ready for testing.'
      ready
      @socket.each_object do |obj|
        break if obj == :shutdown
        @socket << (run_suite(obj) ? :success : :failure)
        ready
      end
    rescue EOFError, Shutdown
      # shutdown
    end

    private

    RESTART = 'RP_RESTARTED'

    def prepare
      restart = false
      begin
        puts "RP: Loading test environment."
        $LOAD_PATH << 'test'
        require 'test_helper'
      rescue Mysql2::Error => e
        raise e if ENV[RESTART]
        puts "RP: Test environment failed to load: #{e.message} (#{e.class})"
        restart = true
      end

      schema_file = @socket.next_object
      raise Shutdown if schema_file == :shutdown
      @schema = Schema.new(schema_file)

      unless ENV[RESTART]
        puts "RP: Loading test schema."
        @schema.load_main_db
      end

      if restart
        puts 'RP: Restarting ...'
        puts
        ENV[RESTART] = '1'
        exec(@script, *ARGV)
        raise "exec failed"
      end

      @socket << :started
    end

    def status(msg)
      $0 = "rails_parallel/master: #{msg}"
    end

    def ready
      status 'idle'
      @socket << :ready
    end

    def run_suite(params)
      parent = Parent.new(@schema, params)
      status "running #{parent.name}"
      parent.run
    end
  end
end
