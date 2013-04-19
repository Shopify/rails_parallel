require 'rails_parallel/forks'
require 'rails_parallel/collector'
require 'rails_parallel/timings'
require 'rails_parallel/schema'
require 'rails_parallel/stats'
require 'rails_parallel/runner/child'
require 'rails_parallel/runner/test_runner'

module RailsParallel
  class Runner
    class Parent
      include Forks

      attr_reader :name

      def initialize(schema, params)
        @schema  = schema
        @name    = params[:name]
        @options = params[:options]
        @files   = params[:files]
        @max_children = RailsParallel.number_of_workers

        @timings = Timings.new

        @children   = []
        @launched   = 0
        @by_pid     = {}
        @by_socket  = {}
        @close_wait = []

        @result = TestRunner.new
        @faults = {}
      end

      def run
        @schema.load_main_db

        pid = fork_and_run do
          status "preparing #{@name}"
          partial "RP: Preparing #{@name} ... "
          handle_options
          prepare
          puts "ready."

          status "running #{@name}"
          puts "RP: Running #{@name}."
          start = Time.now
          exception = nil
          begin
            launch_next_child
            monitor
          rescue Exception => e
            exception = e
          ensure
            @children.each(&:kill)
            output_result(Time.now - start)

            if exception
              puts "RP: Suite failed: #{exception.message} (#{exception.class.name})"
              puts "Backtrace:\n\t" + exception.backtrace.join("\n\t")
            end

            success = exception.nil? && success?
            Kernel.exit!(success ? 0 : 1)
          end
        end

        begin
          wait_for(pid)
          true
        rescue ChildFailed
          false
        end
      end

      private

      def partial(msg)
        $stdout.print(msg)
        $stdout.flush
      end

      def handle_options
        @options.each do |opt, value|
          case opt
          when :require
            value = 'rubygems' if value == 'ubygems'
            partial "#{value}, "
            require value
          else
            raise "Unknown option type: #{opt}"
          end
        end
      end

      def prepare
        partial "#{@files.count} test files ... "
        @files.each { |f| load f }
        @collector = Collector.new
        @collector.prepare(@timings, @name)

        count = @collector.suite_count
        @max_children = count if count < @max_children
      end

      def launch_next_child
        return if @launched >= @max_children
        return if @complete

        child = Child.new(@launched += 1, @schema, @collector)
        child.launch

        @children << child
        @by_pid[child.pid] = child
        @by_socket[child.socket] = child
        update_status
      end

      def monitor
        @stats = Stats.new
        until @children.empty?
          watching = @children.map(&:socket)
          IO.select(watching).first.each do |socket|
            child = @by_socket[socket]

            begin
              child.poll.each do |packet|
                case packet
                when :started
                  launch_next_child
                when :ready
                  suite = @collector.next_suite
                  if suite
                    child.run_suite(suite)
                  else
                    @complete = true
                    @stats.finish(child.number)
                    child.finish
                  end
                when :finished
                  close_child(child)
                else
                  suite, result = packet
                  @result.append(result)
                  @faults[suite] = result.report
                  @collector.complete(suite)

                  if result.test_count > 0
                    duration = Time.now - child.last_time
                    @timings.record(@name, child.last_suite, duration)
                    @stats.add(child.number, child.last_suite, duration)
                  end

                  update_status
                end
              end
            rescue EOFError => e
              raise "Child ##{child.number} (#{child.pid}) died unexpectedly"
            end
          end

          wait_loop(true)
        end

        @timings.flush
        wait_loop(false)

        report = @stats.slow_report
        if report.show?
          puts
          report.output.each { |msg| puts "RP: #{msg}" }
        end
      end

      def wait_loop(nonblock)
        return if @close_wait.empty?

        while !@close_wait.empty? && pid = wait_any(nonblock)
          @close_wait.delete(pid)
        end
      end

      def close_child(child)
        child.close rescue nil
        @children.delete(child)
        @by_socket.delete(child.socket)
        @by_pid.delete(child.pid)
        @close_wait << child.pid
        update_status
        @stats.finish(child.number)
      end

      def output_result(elapsed)
        @result.output_report(elapsed)
      end

      def success?
        @faults.values.all?(&:empty?)
      end

      def update_status
        percent  = @collector.complete_percent
        message  = "running #{@name}, #{@children.count} workers"
        message += ", #{percent.floor}% complete" if percent
        status message
      end

      def status(msg)
        $0 = "rails_parallel/parent: #{msg}"
      end
    end
  end
end
