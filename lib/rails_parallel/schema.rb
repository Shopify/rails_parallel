require 'rails_parallel/forks'

module RailsParallel
  class Schema
    include Forks

    def initialize(file)
      @file = file
    end

    def load_main_db
      if load_db(1)
        failed = 0
        ObjectSpace.each_object(Class) do |klass|
          next unless klass < ActiveRecord::Base

          klass.reset_column_information
          begin
            klass.columns
          rescue StandardError => e
            failed += 1
            raise e if failed > 3
          end
        end
      end
    end

    def load_db(number)
      update_db_config(number)
      return false if schema_loaded?

      schema_load
      true
    end

    private

    def reconnect(override = {})
      ActiveRecord::Base.clear_active_connections!
      ActiveRecord::Base.establish_connection(@dbconfig.merge(override))
      ActiveRecord::Base.connection
    end

    def update_db_config(number)
      config = ActiveRecord::Base.configurations[Rails.env]
      config['database'] += "_#{number}" unless number == 1
      @dbconfig = config.with_indifferent_access
    end

    def schema_load
      dbname = @dbconfig[:database]
      mysql_args = ['-u', 'root']

      connection = reconnect(:database => nil)
      connection.execute("DROP DATABASE IF EXISTS #{dbname}")
      connection.execute("CREATE DATABASE #{dbname}")

      File.open(@file) do |fh|
        pid = fork do
          STDIN.reopen(fh)
          exec(*['mysql', mysql_args, dbname].flatten)
        end
        wait_for(pid)
      end

      reconnect
      sm_table = ActiveRecord::Migrator.schema_migrations_table_name
      ActiveRecord::Base.connection.execute("INSERT INTO #{sm_table} (version) VALUES ('#{@file}')")
    end

    def schema_loaded?
      reconnect

      sm_table = ActiveRecord::Migrator.schema_migrations_table_name
      migrated = ActiveRecord::Base.connection.select_values("SELECT version FROM #{sm_table}")
      migrated.include?(@file)
    rescue
      return false
    end
  end
end
