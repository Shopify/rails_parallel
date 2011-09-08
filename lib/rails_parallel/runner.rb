require 'rails_parallel/runner/parent'
require 'rails_parallel/object_socket'

module RailsParallel
  class Runner
    def self.launch(socket)
      Runner.new(socket).run
    end

    def initialize(socket)
      @socket = socket
    end

    def run
      prepare

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
