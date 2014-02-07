require 'rails_parallel/object_socket'
require 'rails_parallel/runner/test_runner'
require 'minitest/unit'

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

        ::RailsParallel::Runner.run_before_fork

        @pid = fork_and_run do
          parent_socket.close
          @socket = child_socket

          @schema.load_db(@number)
          ::RailsParallel::Runner.run_after_fork(@number)

          main_loop
          ::RailsParallel::Runner.run_before_exit(@number)
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
        Process.kill('KILL', @pid) rescue nil
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
        @socket << :started << :ready

        @socket.each_object do |obj|
          break if obj == :finish

          $0 = "rails_parallel/worker: #{obj}"
          ($rp_suites ||= []) << obj
          suite = @collector.suite_for(obj)
          runner = TestRunner.new
          begin
            runner.test_count, runner.assertion_count = runner._run_suite(suite, :test)
          rescue Exception => e
            $stderr.puts "\nRP: Test suite error while running #{obj}."
            raise e
          end

          @socket << [obj, runner] << :ready
        end

        @socket << :finished
        @socket.next_object rescue nil # wait for EOFError to avoid race condition
      end
    end
  end
end
