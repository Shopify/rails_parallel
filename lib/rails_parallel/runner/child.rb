require 'rails_parallel/object_socket'
require 'rails_parallel/runner/test_runner'

module RailsParallel
  class Runner
    class Child
      include Forks

      attr_reader :socket, :pid, :number, :last_suite, :last_time

      def initialize(number, schema, collector)
        @number = number
        @schema = schema
        @collector = collector
        @buffer = ''
        @state  = :waiting
      end

      def launch
        parent_socket, child_socket = ObjectSocket.pair

        @pid = fork_and_run do
          parent_socket.close
          @socket = child_socket
          main_loop
        end

        child_socket.close
        @socket = parent_socket
        @socket.nonblock = true
      end

      def run_suite(name)
        @last_suite = name
        @last_time  = Time.now
        @socket << name
      end

      def finish
        @socket << :finish
      end

      def close
        @socket.close
      end

      def kill
        Process.kill('KILL', @pid)
        close rescue nil
      end

      def socket
        @socket.socket
      end

      def poll
        output = []
        @socket.each_object { |obj| output << obj }
        output
      end

      private

      def main_loop
        @schema.load_db(@number)

        @socket << :started << :ready

        @socket.each_object do |obj|
          break if obj == :finish

          ($rp_suites ||= []) << obj
          suite = @collector.suite_for(obj)
          runner = TestRunner.new(suite)
          runner.start

          @socket << [obj, runner.result, runner.faults] << :ready
        end

        @socket << :finished
      end
    end
  end
end
