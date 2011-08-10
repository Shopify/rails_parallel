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

      @socket << :ready
      @socket.each_object do |obj|
        break if obj == :shutdown
        @socket << (run_suite(obj) ? :success : :failure)
        @socket << :ready
      end
    rescue EOFError
      # shutdown
    end

    private

    def prepare
      $LOAD_PATH << 'test'
      require 'test_helper'
    end

    def run_suite(params)
      Parent.new(params).run
    end
  end
end
