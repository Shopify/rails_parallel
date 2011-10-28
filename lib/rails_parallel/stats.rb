module RailsParallel
  class Stats

    class Entry
      attr_reader :finish_time

      SKIP_DURATION = 0.01 # very short tests are omitted

      def initialize(id)
        @id = id
        @suites = []
      end

      def add(suite, duration)
        @suites << [suite, duration] unless duration < SKIP_DURATION
      end

      def finish
        @finish_time ||= Time.now
      end

      def single?
        @suites.count == 1
      end

      def suite
        raise "not a single suite" unless single?
        @suites.first.first
      end

      def duration
        @suites.map(&:last).sum
      end

      def suite_count
        @suites.count
      end
    end


    SLOW_TIME_FACTOR  = 1.1 # must extend suite by 10%
    SLOW_TIME_SECONDS = 3   # ... and extend suite by at least 3 seconds (for short suites)
    SLOW_COUNT_FACTOR = 1.5 # there must be 1.5x as many multi-tests as single-tests

    def initialize
      @children   = Hash.new { |h,k| h[k] = Entry.new(k) }
      @start_time = Time.now
    end

    def add(child_id, suite, duration)
      @children[child_id].add(suite, duration)
    end

    def finish(child_id)
      @children[child_id].finish
    end

    def find_slow_suites
      singles, multis = @children.values.partition(&:single?)
      return [] if multis.empty?

      multi_count = multis.map(&:suite_count).sum
      return [] unless multi_count > singles.count * SLOW_COUNT_FACTOR

      multi_finish   = multis.map(&:finish_time).max
      multi_duration = multi_finish - @start_time

      slow = singles.select { |e|
        e.duration > multi_duration * SLOW_TIME_FACTOR &&
        e.duration - multi_duration > SLOW_TIME_SECONDS
      }
      slow.sort_by(&:duration).reverse.map do |entry|
        factor = (entry.duration - multi_duration) * 100.0 / multi_duration
        "#{entry.suite} took #{'%.2f' % entry.duration}s and extended the suite by #{factor.round}%"
      end
    end
  end
end
