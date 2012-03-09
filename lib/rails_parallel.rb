module RailsParallel
  # Just a utility class.  Require 'rails_parallel/rake' in your Rakefile if you want RP.

  def self.redis
    @@redis ||= Redis.new(:db => ENV['RP_REDIS_DB'] || 15)
  end

  def self.redis=(r)
    @@redis = r
  end
end
