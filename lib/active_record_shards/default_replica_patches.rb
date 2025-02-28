# frozen_string_literal: true

module ActiveRecordShards
  module DefaultReplicaPatches
    def self.wrap_method_in_on_replica(class_method, base, method, force_on_replica: false)
      base_methods =
        if class_method
          base.methods + base.private_methods
        else
          base.instance_methods + base.private_instance_methods
        end

      return unless base_methods.include?(method)

      _, method, punctuation = method.to_s.match(/^(.*?)([\?\!]?)$/).to_a
      # _ALWAYS_ on replica, or only for on `on_replica_by_default = true` models?
      wrapper = force_on_replica ? 'force_on_replica' : 'on_replica_unless_tx'
      base.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        #{class_method ? 'class << self' : ''}
          def #{method}_with_default_replica#{punctuation}(*args, &block)
            #{wrapper} do
              #{method}_without_default_replica#{punctuation}(*args, &block)
            end
          end

          alias_method :#{method}_without_default_replica#{punctuation}, :#{method}#{punctuation}
          alias_method :#{method}#{punctuation}, :#{method}_with_default_replica#{punctuation}
        #{class_method ? 'end' : ''}
      RUBY
    end

    def self.wrap_method_in_on_slave(*args)
      ActiveRecordShards::Deprecation.deprecation_warning(
        :'self.wrap_method_in_on_slave',
        :'self.wrap_method_in_on_replica'
      )
      wrap_method_in_on_replica(*args)
    end

    def transaction_with_replica_off(*args, &block)
      if on_replica_by_default?
        begin
          old_val = Thread.current[:_active_record_shards_in_tx]
          Thread.current[:_active_record_shards_in_tx] = true
          transaction_without_replica_off(*args, &block)
        ensure
          Thread.current[:_active_record_shards_in_tx] = old_val
        end
      else
        transaction_without_replica_off(*args, &block)
      end
    end
    alias_method :transaction_with_slave_off, :transaction_with_replica_off

    module InstanceMethods
      # fix ActiveRecord to do the right thing, and use our aliased quote_value
      def quote_value(*args, &block)
        self.class.quote_value(*args, &block)
      end

      def on_replica_unless_tx
        self.class.on_replica_unless_tx { yield }
      end
    end

    CLASS_REPLICA_METHODS = [
      :calculate,
      :count_by_sql,
      :exists?,
      :find,
      :find_by,
      :find_by_sql,
      :find_every,
      :find_one,
      :find_some,
      :get_primary_key
    ].freeze

    CLASS_FORCE_REPLICA_METHODS = [
      :replace_bind_variable,
      :replace_bind_variables,
      :sanitize_sql_array,
      :sanitize_sql_hash_for_assignment,
      :table_exists?
    ].freeze

    CLASS_SLAVE_METHODS = CLASS_REPLICA_METHODS
    CLASS_FORCE_SLAVE_METHODS = CLASS_FORCE_REPLICA_METHODS

    def self.extended(base)
      CLASS_REPLICA_METHODS.each { |m| ActiveRecordShards::DefaultReplicaPatches.wrap_method_in_on_replica(true, base, m) }
      CLASS_FORCE_REPLICA_METHODS.each { |m| ActiveRecordShards::DefaultReplicaPatches.wrap_method_in_on_replica(true, base, m, force_on_replica: true) }

      if ActiveRecord::VERSION::MAJOR >= 5
        ActiveRecordShards::DefaultReplicaPatches.wrap_method_in_on_replica(true, base, :load_schema!, force_on_replica: true)
      else
        ActiveRecordShards::DefaultReplicaPatches.wrap_method_in_on_replica(true, base, :columns, force_on_replica: true)
      end

      ActiveRecordShards::DefaultReplicaPatches.wrap_method_in_on_replica(false, base, :reload)

      base.class_eval do
        include InstanceMethods

        class << self
          alias_method :transaction_without_replica_off, :transaction
          alias_method :transaction, :transaction_with_replica_off
        end
      end
    end

    def on_replica_unless_tx(&block)
      return yield if Thread.current[:_active_record_shards_in_migration]
      return yield if Thread.current[:_active_record_shards_in_tx]

      if on_replica_by_default?
        on_replica(&block)
      else
        yield
      end
    end
    alias_method :on_slave_unless_tx, :on_replica_unless_tx

    def force_on_replica(&block)
      return yield if Thread.current[:_active_record_shards_in_migration]

      on_cx_switch_block(:replica, construct_ro_scope: false, force: true, &block)
    end

    module ActiveRelationPatches
      def self.included(base)
        [:calculate, :exists?, :pluck, :load].each do |m|
          ActiveRecordShards::DefaultReplicaPatches.wrap_method_in_on_replica(false, base, m)
        end

        if ActiveRecord::VERSION::MAJOR == 4
          # `where` and `having` clauses call `create_binds`, which will use the primary connection
          ActiveRecordShards::DefaultReplicaPatches.wrap_method_in_on_replica(false, base, :create_binds, force_on_replica: true)
        end

        ActiveRecordShards::DefaultReplicaPatches.wrap_method_in_on_replica(false, base, :to_sql, force_on_replica: true)
      end

      def on_replica_unless_tx
        @klass.on_replica_unless_tx { yield }
      end
    end

    module Rails52RelationPatches
      def connection
        return super if Thread.current[:_active_record_shards_in_migration]
        return super if Thread.current[:_active_record_shards_in_tx]

        if @klass.on_replica_by_default?
          @klass.on_replica.connection
        else
          super
        end
      end
    end

    # in rails 4.1+, they create a join class that's used to pull in records for HABTM.
    # this simplifies the hell out of our existence, because all we have to do is inerit on-replica-by-default
    # down from the parent now.
    module Rails41HasAndBelongsToManyBuilderExtension
      def self.included(base)
        base.class_eval do
          alias_method :through_model_without_inherit_default_replica_from_lhs, :through_model
          alias_method :through_model, :through_model_with_inherit_default_replica_from_lhs
        end
      end

      def through_model_with_inherit_default_replica_from_lhs
        model = through_model_without_inherit_default_replica_from_lhs
        def model.on_replica_by_default?
          left_reflection.klass.on_replica_by_default?
        end

        # also transfer the sharded-ness of the left table to the join model
        model.not_sharded unless model.left_reflection.klass.is_sharded?
        model
      end
    end

    module AssociationsAssociationAssociationScopePatch
      def association_scope
        if klass
          on_replica_unless_tx { super }
        else
          super
        end
      end

      def on_replica_unless_tx
        klass.on_replica_unless_tx { yield }
      end
    end

    module AssociationsAssociationFindTargetPatch
      def find_target
        if klass
          on_replica_unless_tx { super }
        else
          super
        end
      end

      def on_replica_unless_tx
        klass.on_replica_unless_tx { yield }
      end
    end

    module AssociationsAssociationGetRecordsPatch
      def get_records # rubocop:disable Naming/AccessorMethodName
        if klass
          on_replica_unless_tx { super }
        else
          super
        end
      end

      def on_replica_unless_tx
        klass.on_replica_unless_tx { yield }
      end
    end

    module AssociationsPreloaderAssociationAssociatedRecordsByOwnerPatch
      def associated_records_by_owner(preloader)
        if klass
          on_replica_unless_tx { super }
        else
          super
        end
      end

      def on_replica_unless_tx
        klass.on_replica_unless_tx { yield }
      end
    end

    module AssociationsPreloaderAssociationLoadRecordsPatch
      def load_records
        if klass
          on_replica_unless_tx { super }
        else
          super
        end
      end

      def on_replica_unless_tx
        klass.on_replica_unless_tx { yield }
      end
    end

    module TypeCasterConnectionConnectionPatch
      def connection
        return super if Thread.current[:_active_record_shards_in_migration]
        return super if Thread.current[:_active_record_shards_in_tx]

        if @klass.on_replica_by_default?
          @klass.on_replica.connection
        else
          super
        end
      end
    end

    module SchemaDefinePatch
      def define(info, &block)
        old_val = Thread.current[:_active_record_shards_in_migration]
        Thread.current[:_active_record_shards_in_migration] = true
        super
      ensure
        Thread.current[:_active_record_shards_in_migration] = old_val
      end
    end
  end
end
