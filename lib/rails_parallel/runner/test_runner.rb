require 'minitest/unit'

module RailsParallel
  class Runner
    class TestRunner < MiniTest::Unit

      def initialize
        @test_count, @assertion_count = 0, 0
        super
      end

      def output_report(t)
        self.test_count ||= 0
        self.assertion_count ||= 0
        puts

        puts "Finished tests in %.6fs, %.4f tests/s, %.4f assertions/s." %
          [t, test_count / t, assertion_count / t]

        report.each_with_index do |msg, i|
          puts "\n%3d) %s" % [i + 1, msg]
        end

        puts

        status
      end

      def append(other)
        @test_count += other.test_count
        @assertion_count += other.assertion_count
        @failures  += other.failures
        @errors    += other.errors
        @report    += other.report
      end

      def marshal_dump
        [@test_count, @assertion_count, @failures, @errors, @report]
      end

      def marshal_load(array)
        @test_count, @assertion_count, @failures, @errors, @report = array
      end

    end
  end
end
