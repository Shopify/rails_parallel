require 'rubygems'
require 'redis'
require 'redis/connection/hiredis'
require 'active_support/core_ext/enumerable'

module RailsParallel
  class Timings
    TIMING_COUNT = 10

    def initialize
      reconnect
      @queue = []
    end

    def record(test_name, class_name, time)
      key = key_for(test_name, class_name)
      @queue << [key, time]
    end

    def fetch(test_name, class_name)
      key = key_for(test_name, class_name)
      times = @cache.lrange(key, 0, TIMING_COUNT - 1).map(&:to_f)
      return 0 if times.empty?
      times.sum / times.count
    end

    def flush
      @queue.each do |key, time|
        begin
          @cache.lpush(key, time)
          @cache.ltrim(key, 0, TIMING_COUNT - 1)
        rescue Errno::EAGAIN, Timeout::Error => e
          puts "RP: Failed to record #{key} (#{e.class.name})."
          reconnect
        end
      end
      @queue = []
    end

    private

    def reconnect
      @cache = Redis.new
    end

    def key_for(test_name, class_name)
      "timings-#{test_name}-#{class_name}"
    end
  end
end
