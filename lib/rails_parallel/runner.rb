require 'rails_parallel/runner/parent'
require 'rails_parallel/object_socket'

module RailsParallel
  class Runner
    def self.launch(socket, script)
      Runner.new(socket, script).run
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
    rescue EOFError
      # shutdown
    end

    private

    def prepare
      $LOAD_PATH << 'test'
      require 'test_helper'
    rescue Mysql2::Error => e
      puts "RP: Test environment failed to load: #{e.message} (#{e.class})"
      @socket << :schema_needed

      msg = @socket.next_object
      raise "Unexpected: #{msg.inspect}" unless msg == :restart

      puts 'RP: Restarting ...'
      puts
      exec(@script, *ARGV)
      raise "exec failed"
    end

    def status(msg)
      $0 = "rails_parallel/master: #{msg}"
    end

    def ready
      status 'idle'
      @socket << :ready
    end

    def run_suite(params)
      parent = Parent.new(params)
      status "running #{parent.name}"
      parent.run
    end
  end
end
