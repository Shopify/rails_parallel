module RailsParallel
  module Forks
    class ChildFailed < StandardError
      attr_reader :status

      def initialize(status)
        @status = status
      end
    end

    def fork_and_run
      ActiveRecord::Base.connection.disconnect! if ActiveRecord::Base.connected?

      fork do
        begin
          yield
          Kernel.exit!(0)
        rescue Interrupt, SignalException
          Kernel.exit!(1)
        rescue Exception => e
          $stderr.puts "Error: #{e}"
          $stderr.puts(*e.backtrace.map {|t| "\t#{t}"})
          [$stdout, $stderr].each(&:flush)
          Kernel.exit!(1)
        end
      end
    end

    def wait_for(pid, nonblock = false)
      pid = Process.waitpid(pid, nonblock ? Process::WNOHANG : 0)
      check_status($?) if pid
      pid
    end

    def wait_any(nonblock = false)
      wait_for(-1, nonblock)
    end

    def check_status(stat)
      raise ChildFailed.new(stat) unless stat.success?
    end
  end
end
