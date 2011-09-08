require 'test/unit/collector'

module RailsParallel
  class Collector
    include Test::Unit::Collector

    NAME = 'collected from the ObjectSpace'

    def prepare(timings, test_name)
      @suites = {}
      ::ObjectSpace.each_object(Class) do |klass|
        @suites[klass.name] = klass.suite if Test::Unit::TestCase > klass
      end

      @pending = @suites.keys.sort_by do |name|
        [
          0 - timings.fetch(test_name, name),  # runtime, descending
          0 - @suites[name].size,              # no. of tests, descending
          name
        ]
      end
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
  end
end
