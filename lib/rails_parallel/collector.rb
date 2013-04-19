module RailsParallel
  class Collector

    NAME = 'collected from the ObjectSpace'

    def prepare(timings, test_name)
      @suites = {}
      ::ObjectSpace.each_object(Class) do |klass|
        @suites[klass.name] = klass if MiniTest::Unit::TestCase > klass
      end

      @times = {}
      @pending = @suites.keys.sort_by do |name|
        time = @times[name] = timings.fetch(test_name, name)
        [
          0 - time,                            # runtime, descending
          0 - @suites[name].test_methods.size, # no. of tests, descending
          name
        ]
      end
      @complete = []
    end

    def next_suite
      @pending.shift
    end

    def suite_for(name)
      @suites[name]
    end

    def suite_count
      @suites.count
    end

    def complete(name)
      @complete << name
    end

    def time_remaining
      @suites.keys.map {|n| @times[n]}.sum
    end

    def time_complete
      @complete.map {|n| @times[n]}.sum
    end

    def complete_percent
      return nil if time_remaining <= 0.0
      time_complete * 100.0 / time_remaining
    end
  end
end
