module RailsParallel
  class Stats

    class Entry
      attr_reader :finish_time

      def initialize(id)
        @id = id
        @suites = []
      end

      def add(suite, duration)
        @suites << [suite, duration]
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

    class SlowReport
      TIME_FORMAT = '%.1fs'

      MIN_EXTEND_PERCENT = 10 # class must extend suite by at least 10%
      MIN_EXTEND_SECONDS = 3  # ... and that must be at least 2 seconds extension
      MIN_SOLO_SECONDS   = 10 # consider a single to be a multi if it's under 10 seconds

      def initialize(start_time, children)
        @start_time = start_time

        @singles, @multis = children.partition(&:single?).map {|list| list.sort_by(&:finish_time) }
        bundle_singles_into_multis
      end

      def bundle_singles_into_multis
        until @singles.empty?
          entry  = @singles.first
          bundle = false

          multi_count  = @multis.map(&:suite_count).sum
          multi_finish = @multis.last.finish_time unless @multis.empty?

          if multi_finish
            extended   = entry.finish_time - multi_finish
            multi_time = multi_finish - @start_time
            percent    = extended * 100 / multi_time
            bundle = true if extended < MIN_EXTEND_SECONDS || percent < MIN_EXTEND_PERCENT
          else
            duration = entry.finish_time - @start_time
            bundle = true if duration < MIN_SOLO_SECONDS
          end

          if bundle
            @multis << @singles.shift
          else
            break
          end
        end
      end

      def show?
        !@singles.empty?
      end

      def output
        output = []
        last_finish = nil

        multi_count = @multis.map(&:suite_count).sum
        base_finish = base_duration = nil
        if multi_count > 0
          multi_finish   = @multis.last.finish_time
          multi_duration = multi_finish - @start_time
          classes = multi_count == 1 ? "class" : "classes"
          output.unshift "#{multi_count} test #{classes} took #{TIME_FORMAT % multi_duration}."

          last_finish   = multi_finish
          base_finish   = multi_finish
          base_duration = multi_duration
        end

        further = false
        @singles.each do |entry|
          begin
            duration  = entry.finish_time - @start_time
            base_text = "#{entry.suite} took #{TIME_FORMAT % duration}"

            if last_finish.nil?
              output << "#{base_text}."
              base_finish   = entry.finish_time
              base_duration = duration
              next
            end

            extended   = entry.finish_time - last_finish
            prior_time = last_finish - @start_time
            percent    = extended * 100.0 / prior_time

            percent_text = "%d%%" % percent
            if further
              percent_text = "a further #{percent_text}"
              if base_finish
                total_extended = entry.finish_time - base_finish
                total_percent  = total_extended * 100 / base_duration
                percent_text += " (total %d%%)" % total_percent
              end
            end

            output << "#{base_text} and extended the suite by #{percent_text}."
            further = true
          ensure
            last_finish = entry.finish_time
          end
        end

        unless @singles.empty?
          classes = @singles.count == 1 ? 'this class' : 'these classes'
          output << "Consider improving or splitting up #{classes} for better performance."
        end

        output
      end
    end

    def slow_report
      SlowReport.new(@start_time, @children.values)
    end
  end
end
