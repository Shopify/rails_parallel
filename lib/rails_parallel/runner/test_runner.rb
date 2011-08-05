require 'test/unit/ui/console/testrunner'

module RailsParallel
  class Runner
    class TestRunner < Test::Unit::UI::Console::TestRunner
      attr_accessor :result, :faults

      def initialize(suite, output_level = Test::Unit::UI::PROGRESS_ONLY)
        super(suite, output_level)
      end

      def output_report(elapsed)
        finished(elapsed)
      end
    end
  end
end
