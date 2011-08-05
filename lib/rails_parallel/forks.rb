module RailsParallel
  module Forks
    def fork_and_run
      ActiveRecord::Base.connection.disconnect! if ActiveRecord::Base.connected?

      fork do
        begin
          yield
          Kernel.exit!(0)
        rescue Interrupt, SignalException
          Kernel.exit!(1)
        rescue Exception => e
          puts "Error: #{e}"
          puts(*e.backtrace.map {|t| "\t#{t}"})
          before_exit
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
      raise "error: #{stat.inspect}" unless stat.success?
    end

    def before_exit
      # cleanup here (in children)
    end
  end
end
