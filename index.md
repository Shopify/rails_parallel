rails_parallel
==============

rails_parallel makes your Rails tests scale with the number of CPU cores available. 

It also speeds up the testing process in general, by making heavy use of forking to only have to load the Rails environment once.

Installation
------------

To load rails_parallel, require "rails_parallel/rake" early in your Rakefile.  One possibility is to load it conditionally based on an environment variable:

    require 'rails_parallel/rake' if ENV['PARALLEL']

You'll want to add a lib/tasks/rails_parallel.rake with at least the following:

    # RailsParallel handles the DB schema.
    Rake::Task['test:prepare'].clear_prerequisites if Object.const_get(:RailsParallel)

    namespace :parallel do
      # Run this task if you have non-test tasks to run first and you want the
      # RailsParallel worker to start loading your environment earlier.
      task :launch do
        RailsParallel::Rake.launch
      end

      namespace :db do
	# RailsParallel runs this if it needs to reload the DB.
        task :setup => ['db:drop', 'db:create', 'db:schema:load']

        # RailsParallel normally doesn't mess with your current DB,
	# only the 'test' env DB.  Run this to load it if required.
        task :load => :environment do
          RailsParallel::Rake.load_current_db
        end
      end
    end

This gem was designed as an internal project and currently makes certain assumptions about your project setup, such as the use of MySQL and a separate versioned schema (rather than db/schema.rb).  These will become more generic in future versions.
