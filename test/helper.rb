# frozen_string_literal: true

require 'bundler/setup'
require 'minitest/autorun'
require 'minitest/rg'
require 'rake'

require 'mocha/minitest'
Bundler.require

$LOAD_PATH.unshift(File.join(__dir__, '..', 'lib'))
$LOAD_PATH.unshift(__dir__)
require 'active_support'
require 'active_record_shards'
require 'support/tcp_proxy'
require 'logger'
require 'phenix'

require 'pry-byebug'

RAILS_ENV = "test"

ActiveRecord::Base.logger = Logger.new(__dir__ + "/test.log")
ActiveSupport.test_order = :sorted
ActiveSupport::Deprecation.behavior = :raise
ActiveRecordShards::Deprecation.behavior = :silence

BaseMigration = (ActiveRecord::VERSION::MAJOR >= 5 ? ActiveRecord::Migration[4.2] : ActiveRecord::Migration) # rubocop:disable Naming/ConstantName

require 'active_support/test_case'

# support multiple before/after blocks per example
module SpecDslPatch
  def before(_type = nil, &block)
    include(Module.new { super })
  end

  def after(_type = nil, &block)
    include(Module.new { super })
  end
end
Minitest::Spec.singleton_class.prepend(SpecDslPatch)

module RakeSpecHelpers
  def show_databases(config)
    client = Mysql2::Client.new(
      host: config['test']['host'],
      port: config['test']['port'],
      username: config['test']['username'],
      password: config['test']['password']
    )
    databases = client.query("SHOW DATABASES")
    databases.map { |d| d['Database'] }
  end

  def rake(name)
    Rake::Task[name].reenable
    Rake::Task[name].invoke
  end
end

module ConnectionSwitchingSpecHelpers
  def assert_using_primary_db
    assert_using_database('ars_test')
  end

  def assert_using_replica_db
    assert_using_database('ars_test_replica')
  end

  def assert_using_database(db_name, model = ActiveRecord::Base)
    assert_equal(db_name, model.connection.current_database)
  end
end

module SpecHelpers
  def self.mysql_url
    URI(ENV['MYSQL_URL'] || 'mysql://root@127.0.0.1:3306')
  end

  @@unsharded_primary_proxy ||= TCPProxy.start(
    remote_host: mysql_url.host,
    remote_port: mysql_url.port,
    local_port: '13306'
  )

  # Verifies that a block of code is not using the unsharded primary by pausing
  # the TCP proxy between Ruby and MySQL.
  def with_unsharded_primary_unavailable
    @@unsharded_primary_proxy.pause do
      yield
    end
  end

  def clear_global_connection_handler_state
    # Close active connections
    ActiveRecord::Base.connection_handler.clear_all_connections!

    # Use a fresh connection handler
    ActiveRecord::Base.connection_handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new

    if ActiveRecord::VERSION::MAJOR == 4
      # Clear out our own global state
      ActiveRecord::Base.send(:clear_specification_cache)
    end
  end

  def table_exists?(name)
    if ActiveRecord::VERSION::MAJOR >= 5
      ActiveRecord::Base.connection.data_source_exists?(name)
    else
      ActiveRecord::Base.connection.table_exists?(name)
    end
  end

  def table_has_column?(table, column)
    !ActiveRecord::Base.connection.select_values("desc #{table}").grep(column).empty?
  end

  def migrator(direction = :up, path = 'migrations', target_version = nil)
    migration_path = File.join(__dir__, "support", path)
    if ActiveRecord::VERSION::MAJOR >= 6
      migrations = ActiveRecord::MigrationContext.new(migration_path, ActiveRecord::SchemaMigration).migrations
      ActiveRecord::Migrator.new(direction, migrations, ActiveRecord::SchemaMigration, target_version)
    elsif ActiveRecord::VERSION::STRING >= "5.2.0"
      migrations = ActiveRecord::MigrationContext.new(migration_path).migrations
      ActiveRecord::Migrator.new(direction, migrations, target_version)
    else
      migrations = ActiveRecord::Migrator.migrations(migration_path)
      ActiveRecord::Migrator.new(direction, migrations, target_version)
    end
  end
end
Minitest::Spec.include(SpecHelpers)

module RailsEnvSwitch
  def switch_rails_env(env)
    before do
      silence_warnings { Object.const_set("RAILS_ENV", env) }
      ActiveRecord::Base.establish_connection(::RAILS_ENV.to_sym)
    end
    after do
      silence_warnings { Object.const_set("RAILS_ENV", 'test') }
      ActiveRecord::Base.establish_connection(::RAILS_ENV.to_sym)
      tmp_sharded_model = Class.new(ActiveRecord::Base)
      assert_equal('ars_test', tmp_sharded_model.connection.current_database)
    end
  end
end

module PhenixHelper
  # create all databases and then tear them down after test
  # avoid doing any shard switching while preparing our databases
  def with_phenix
    before do
      clear_global_connection_handler_state

      ActiveRecord::Base.stubs(:with_default_shard).yields

      # Create intentionally empty databases
      Phenix.configure do |config|
        config.skip_database = lambda do |name, _|
          intentionally_empty_databases = %w[test3 test3_shard_0]

          !intentionally_empty_databases.include?(name)
        end
      end
      Phenix.rise!(with_schema: false)

      # Populate unsharded databases
      Phenix.configure do |config|
        config.schema_path = File.join(__dir__, 'support', 'unsharded_schema.rb')
        config.skip_database = lambda do |name, _|
          sharded_databases = %w[test_shard_0 test_shard_0_replica test_shard_1 test_shard_1_replica]
          intentionally_empty_databases = %w[test3 test3_shard_0]

          sharded_databases.include?(name) ||
            intentionally_empty_databases.include?(name)
        end
      end
      Phenix.rise!(with_schema: true)

      # Populate sharded databases
      Phenix.configure do |config|
        config.schema_path = File.join(__dir__, 'support', 'sharded_schema.rb')
        config.skip_database = lambda do |name, _|
          unsharded_databases = %w[test test_replica test2 test2_replica]
          intentionally_empty_databases = %w[test3 test3_shard_0]

          unsharded_databases.include?(name) ||
            intentionally_empty_databases.include?(name)
        end
      end
      Phenix.rise!(with_schema: true)

      ActiveRecord::Base.unstub(:with_default_shard)
    end

    after do
      Phenix.burn!
    end
  end
end
Minitest::Spec.extend(PhenixHelper)
