module RailsParallel
  class SafeException
    class SafeClass
      attr_reader :name

      def initialize(cls)
        @name = cls.name
      end
    end

    attr_reader :class, :message, :backtrace

    def initialize(ex)
      @class     = SafeClass.new(ex.class)
      @message   = ex.message.to_s
      @backtrace = ex.backtrace.map(&:to_s)
    end
  end
end
