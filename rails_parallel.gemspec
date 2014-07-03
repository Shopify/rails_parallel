# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "rails_parallel/version"

Gem::Specification.new do |s|
  s.name        = "rails_parallel"
  s.version     = RailsParallel::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Adrian Irving-Beer"]
  s.email       = ["adrian@shopify.com"]
  s.homepage    = ""
  s.summary     = %q{Runs multiple Rails tests concurrently}
  s.description = %q{rails_parallel runs your Rails tests by forking off a worker and running multiple tests concurrently.  It makes heavy use of forking to reduce memory footprint (assuming copy-on-write), only loads your Rails environment once, and automatically scales to the number of cores available.  Designed to work with MySQL only.  For best results, run MySQL on a tmpfs or a RAM disk.}

  s.rubyforge_project = "rails_parallel"

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]

  s.add_dependency 'redis', '~> 3.0'
  s.add_dependency 'rails', '>= 3.0'
  
  s.add_development_dependency 'minitest', '~> 4.7.4'
  s.add_development_dependency 'rake',  '~> 0.9.2'
end
