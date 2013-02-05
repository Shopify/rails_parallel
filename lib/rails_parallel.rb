module RailsParallel
  # Just a utility class.  Require 'rails_parallel/rake' in your Rakefile if you want RP.

  def self.redis
    @@redis ||= Redis.new(:db => ENV['RP_REDIS_DB'] || 15)
  end

  def self.redis=(r)
    @@redis = r
  end

  def self.number_of_workers
    workers = ENV['RAILS_PARALLEL_WORKERS'].to_i
    return workers if workers > 0

    workers = number_of_cores
    workers -= 1 if workers > 4 # reserve one core for DB
    workers
  end

  def self.number_of_cores
    if RUBY_PLATFORM =~ /linux/
      cores = File.read('/proc/cpuinfo').split("\n\n").map do |data|
        values = data.split("\n").map { |line| line.split(/\s*:/, 2) }
        Hash[*values.flatten]
      end

      if cores.first['flags'].include?('hypervisor')
        cores.first['siblings'].to_i
      else
        cores.map {|c| [c['physical id'], c['core id']] }.uniq.count
      end
    elsif RUBY_PLATFORM =~ /darwin/
      `/usr/sbin/sysctl -n hw.physicalcpu`.to_i
    else
      raise "Cannot determine number of cores"
    end
  end
end
