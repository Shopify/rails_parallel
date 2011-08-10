require 'rails_parallel/forks'
require 'rails_parallel/collector'
require 'rails_parallel/timings'
require 'rails_parallel/schema'
require 'rails_parallel/runner/child'
require 'rails_parallel/runner/test_runner'

class Test::Unit::TestResult
  attr_reader :failures, :errors

  def append(other)
    @run_count += other.run_count
    @assertion_count += other.assertion_count
    @failures  += other.failures
    @errors    += other.errors
  end
end

module RailsParallel
  class Runner
    class Parent
      include Forks

      def initialize(params)
        @name    = params[:name]
        @schema  = Schema.new(params[:schema])
        @options = params[:options]
        @files   = params[:files]
        @max_children = number_of_workers

        @timings = Timings.new

        @children  = []
        @launched  = 0
        @by_pid    = {}
        @by_socket = {}

        @result = Test::Unit::TestResult.new
        @faults = {}
      end

      def run
        @schema.load_main_db

        pid = fork_and_run do
          status "RP: Preparing #{@name} ... "
          handle_options
          prepare
          puts "ready."

          puts "RP: Running #{@name}."
          start = Time.now
          begin
            launch_next_child
            monitor
          ensure
            @children.each(&:kill)
            output_result(Time.now - start)
          end
        end
        wait_for(pid)
      end

      private

      def status(msg)
        $stdout.print(msg)
        $stdout.flush
      end

      def handle_options
        @options.each do |opt, value|
          case opt
          when :require
            value = 'rubygems' if value == 'ubygems'
            status "#{value}, "
            require value
          else
            raise "Unknown option type: #{opt}"
          end
        end
      end

      def prepare
        status "#{@files.count} test files ... "
        @files.each { |f| load f }
        @collector = Collector.new
        @collector.prepare(@timings, @name)
      end

      def launch_next_child
        return if @launched >= @max_children
        return if @complete

        child = Child.new(@launched += 1, @schema, @collector)
        child.launch

        @children << child
        @by_pid[child.pid] = child
        @by_socket[child.socket] = child
      end

      def monitor
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
                  @timings.record(@name, child.last_suite, Time.now - child.last_time) if child.last_suite

                  suite = @collector.next_suite
                  if suite
                    child.run_suite(suite)
                  else
                    @complete = true
                    child.finish
                  end
                when :finished
                  close_child(child)
                else
                  suite, result, faults = packet
                  @result.append(result)
                  @faults[suite] = faults
                end
              end
            rescue EOFError
              close_child(child)
            end
          end

          while pid = wait_any(true)
            child = @by_pid[pid]
            close_child(child) if child
            break if @children.empty?
          end
        end
      end

      def close_child(child)
        child.close rescue nil
        @children.delete(child)
        @by_socket.delete(child.socket)
        @by_pid.delete(child.pid)
      end

      def output_result(elapsed)
        runner = TestRunner.new(nil, Test::Unit::UI::NORMAL)
        runner.result = @result
        runner.faults = @faults.sort.map(&:last).flatten(1)

        runner.output_report(elapsed)
      end

      def number_of_workers
        workers = number_of_cores
        workers -= 1 if workers > 4 # reserve one core for DB
        workers
      end

      def number_of_cores
        if RUBY_PLATFORM =~ /linux/
          cores = File.read('/proc/cpuinfo').split("\n\n").map do |data|
            values = data.split("\n").map { |line| line.split(/\s*:/, 2) }
            attrs  = Hash[*values.flatten]
            ['physical id', 'core id'].map { |key| attrs[key] }.join("/")
          end
          cores.uniq.count
        elsif RUBY_PLATFORM =~ /darwin/
          `/usr/bin/hwprefs cpu_count`.to_i
        end
      end
    end
  end
end
