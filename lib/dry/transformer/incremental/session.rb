# frozen_string_literal: true

module Dry
  module Transformer
    module Incremental
      # Maintains materialized output and emits deltas for stable row IDs
      #
      # @api public
      class Session
        EMPTY_DELTA = {inserted: [], updated: [], deleted: []}.freeze

        # @api private
        attr_reader :id_key, :compiler, :result

        # @api public
        def initialize(pipeline, rows = [], id_key: :id)
          @id_key = id_key
          @compiler = Compiler.new(pipeline_ast(pipeline))
          @order = []
          @rows = {}
          @prepared = {}
          reset_terminal_state
          @result = []

          initialize_rows(rows)
          materialize!
        end

        # Build a session from a Pipe instance or class
        #
        # @api public
        def self.from_pipe(pipe, rows = [], **options)
          if pipe.is_a?(Class)
            new(pipe.new.transproc.to_ast, rows, **options)
          else
            new(pipe.transproc.to_ast, rows, **options)
          end
        end

        # Apply one event or a sequence of events and return the net delta
        #
        # @api public
        def call(events)
          list = events.is_a?(Hash) ? [events] : Array(events)
          return EMPTY_DELTA.dup if list.empty?

          before = snapshot
          list.each { |event| apply_event(event) }
          materialize!
          diff(before)
        end
        alias_method :apply, :call

        # Replace all source rows and return the net delta
        #
        # @api public
        def replace(rows)
          before = snapshot
          @order = []
          @rows = {}
          @prepared = {}
          reset_terminal_state
          initialize_rows(rows)
          materialize!
          diff(before)
        end

        # @api public
        def rows
          @order.map { |id| {id_key => id}.merge(@rows[id]) }
        end

        private

        def pipeline_ast(pipeline)
          return pipeline.to_ast if pipeline.respond_to?(:to_ast)

          pipeline
        end

        def initialize_rows(input)
          normalized =
            case input
            when Hash then normalize_hash_input(input)
            when Array then normalize_array_input(input)
            else
              raise ArgumentError, "rows must be an Array or an ID-indexed Hash"
            end

          normalized.each do |id, row|
            add_row(id, row)
          end
        end

        def normalize_hash_input(input)
          input.map do |id, row|
            raise_invalid("row #{id.inspect} must be a Hash") unless row.is_a?(Hash)

            if row.key?(id_key) && row[id_key] != id
              raise_invalid("row #{id.inspect} has conflicting #{id_key.inspect}")
            end

            [id, row.reject { |key, _| key == id_key }]
          end
        end

        def normalize_array_input(input)
          input.each_with_index.map do |row, index|
            unless row.is_a?(Hash) && row.key?(id_key)
              raise_invalid("row at index #{index} must include #{id_key.inspect}")
            end

            id = row[id_key]
            [id, row.reject { |key, _| key == id_key }]
          end
        end

        def add_row(id, row)
          if @rows.key?(id)
            raise DuplicateRowError, "duplicate row ID #{id.inspect}"
          end

          @order << id
          @rows[id] = deep_dup(row)
          set_prepared(id, @rows[id])
        end

        def apply_event(event)
          raise_invalid("event must be a Hash") unless event.is_a?(Hash)

          operation = event[:op] || event["op"] || :update
          id = event_id(event)
          raise_invalid("event must include id") if id.nil?

          case operation.to_sym
          when :insert, :create, :add
            row = event[:row] || event["row"] || event.except(:op, :id, "op", "id")
            insert(id, nested_event_row(id, row))
          when :update, :change
            changes = event[:changes] || event["changes"] || event.except(:op, :id, "op", "id")
            update(id, changes)
          when :delete, :remove
            delete(id)
          else
            raise_invalid("unknown event operation #{operation.inspect}")
          end
        end

        def event_id(event)
          alternate_id_key = id_key.is_a?(Symbol) ? id_key.to_s : id_key.to_sym

          if event.key?(id_key)
            event[id_key]
          elsif event.key?(alternate_id_key)
            event[alternate_id_key]
          elsif event.key?(:id)
            event[:id]
          else
            event["id"]
          end
        end

        def nested_event_row(id, row)
          raise_invalid("event for #{id.inspect} must include a Hash row") unless row.is_a?(Hash)

          row = row.dup
          explicit_id = row.delete(id_key)
          alternate_id =
            if id_key.is_a?(Symbol)
              row.delete(id_key.to_s)
            else
              row.delete(id_key.to_sym)
            end

          [explicit_id, alternate_id].each do |candidate|
            if !candidate.nil? && candidate != id
              raise_invalid("event row has conflicting #{id_key.inspect}")
            end
          end

          row
        end


        def insert(id, row)
          add_row(id, row)
        end

        def update(id, changes)
          raise MissingRowError, "cannot update missing row ID #{id.inspect}" unless @rows.key?(id)

          changes = changes || {}
          raise_invalid("update event for #{id.inspect} must include changes") unless changes.is_a?(Hash)
          if changes.key?(id_key)
            raise_invalid("row ID #{id_key.inspect} is stable and cannot be updated")
          end

          @rows[id].merge!(changes)
          set_prepared(id, @rows[id])
        end

        def delete(id)
          raise MissingRowError, "cannot delete missing row ID #{id.inspect}" unless @rows.key?(id)

          @order.delete(id)
          @rows.delete(id)
          remove_visible(id)
        end

        def materialize!
          @result =
            if compiler.terminal?
              materialize_terminal
            else
              visible_order.filter_map { |id| output_row(id) }
            end
        end

        def visible_order
          @order.select { |id| @prepared.key?(id) }
        end

        def set_prepared(id, row)
          previous = @prepared[id]
          prepared = compiler.pre_terminal(source_row(id, row))

          if previous && prepared.nil?
            remove_visible(id)
          elsif previous.nil? && prepared
            @prepared[id] = prepared
            add_terminal(id, prepared) if compiler.terminal?
          elsif prepared
            @prepared[id] = prepared
            update_visible(id, previous, prepared)
          end
        end

        def source_row(id, row)
          {id_key => id}.merge(row)
        end

        def add_visible(id, row)
          @prepared[id] = row
          add_terminal(id, row)
        end

        def update_visible(id, old_row, new_row)
          return if old_row == new_row

          remove_terminal(id, old_row)
          add_terminal(id, new_row)
        end

        def remove_visible(id)
          old_row = @prepared.delete(id)
          remove_terminal(id, old_row) if old_row
        end

        def reset_terminal_state
          @group_contributions = {}
          @group_children = Hash.new { |hash, root| hash[root] = [] }
          @group_order = []

          @aggregate_buckets = Hash.new do |hash, group_key|
            hash[group_key] = empty_aggregate_bucket(compiler.aggregate_options)
          end
          @aggregate_order = []
        end

        def add_terminal(id, row)
          case compiler.terminal&.first
          when :group then add_group(id, row)
          when :aggregate then add_aggregate(id, row)
          end
        end

        def remove_terminal(id, row)
          case compiler.terminal&.first
          when :group then remove_group(id)
          when :aggregate then remove_aggregate(row)
          end
        end

        def output_row(id)
          row = @prepared[id]
          {id_key => id}.merge(row)
        end

        def materialize_terminal
          case compiler.terminal.first
          when :group then materialize_group
          when :aggregate then materialize_aggregate
          else []
          end
        end

        def materialize_group
          options = compiler.group_options
          @group_order.map do |root|
            root.merge(options[:key] => @group_children[root])
          end
        end

        def group_partition(row, options, row_id)
          row_with_id = {id_key => row_id}.merge(row)
          source =
            if options[:keys].include?(id_key)
              row_with_id
            else
              row_with_id.reject { |key, _| key == id_key }
            end
          old_group = Coercions.to_tuples(source.delete(options[:key]))
          child = {}

          options[:keys].each do |key|
            child[key] = source.delete(key) if source.key?(key)
          end

          [source, old_group.map { |item| item.merge(child) }]
        end

        def materialize_aggregate
          options = compiler.aggregate_options
          @aggregate_order.map do |group_key|
            tuple = options[:group_keys].zip(group_key).to_h
            bucket = @aggregate_buckets[group_key]
            tuple[options[:count_key]] = bucket[:count] if options[:count_key]
            options[:sum_mapping].each_key do |output_key|
              tuple[output_key] = bucket[:sums][output_key]
            end
            tuple
          end
        end

        def empty_aggregate_bucket(options)
          {
            count: 0,
            sums: options[:sum_mapping].to_h { |key, _| [key, 0] }
          }
        end

        def add_group(id, row)
          options = compiler.group_options
          root, children = group_partition(row, options, id)

          @group_contributions[id] = [root, children]
          insert_group_children(root, id, children)
          if @group_order.include?(root)
            reposition_group(root)
          else
            @group_order.insert(group_insert_index(root), root)
          end
        end

        def remove_group(id)
          root, children = @group_contributions.delete(id)
          return unless root

          remove_group_children(root, children)
          remaining = visible_order.any? do |visible_id|
            @group_contributions[visible_id]&.first == root
          end
          if remaining
            reposition_group(root)
          else
            @group_children.delete(root)
            @group_order.delete(root)
          end
        end

        def insert_group_children(root, id, children)
          anchor = visible_order.index(id)
          position = 0

          visible_order[0...anchor].each do |visible_id|
            contribution_root, contribution_children = @group_contributions[visible_id]
            position += contribution_children.size if contribution_root == root
          end

          children.each_with_index do |child, offset|
            @group_children[root].insert(position + offset, child)
          end
        end

        def remove_group_children(root, children)
          remaining = children.tally
          @group_children[root].reject! do |child|
            next false unless remaining.key?(child) && remaining[child].positive?

            remaining[child] -= 1
            true
          end
        end

        def reposition_group(root)
          @group_order.delete(root)
          @group_order.insert(group_insert_index(root), root)
        end

        def group_insert_index(root)
          anchor = visible_order.index { |visible_id|
            @group_contributions[visible_id]&.first == root
          }
          return @group_order.size unless anchor

          @group_order.index { |existing_root|
            existing_anchor = visible_order.index { |visible_id|
              @group_contributions[visible_id]&.first == existing_root
            }
            existing_anchor && existing_anchor > anchor
          } || @group_order.size
        end

        def add_aggregate(_id, row)
          options = compiler.aggregate_options
          source = aggregate_source(row, options)
          group_key = source.values_at(*options[:group_keys])
          if @aggregate_order.include?(group_key)
            reposition_aggregate(options, group_key)
          else
            @aggregate_order.insert(aggregate_insert_index(options, group_key), group_key)
          end

          bucket = @aggregate_buckets[group_key]
          bucket[:count] += 1
          add_sum_values(bucket, source, options)
        end

        def remove_aggregate(row)
          options = compiler.aggregate_options
          source = aggregate_source(row, options)
          group_key = source.values_at(*options[:group_keys])
          bucket = @aggregate_buckets[group_key]
          return unless bucket

          bucket[:count] -= 1
          subtract_sum_values(bucket, source, options)

          if bucket[:count].zero?
            @aggregate_buckets.delete(group_key)
            @aggregate_order.delete(group_key)
          else
            reposition_aggregate(options, group_key)
          end
        end

        def reposition_aggregate(options, group_key)
          @aggregate_order.delete(group_key)
          @aggregate_order.insert(aggregate_insert_index(options, group_key), group_key)
        end

        def aggregate_insert_index(options, group_key)
          anchor = visible_order.index do |id|
            source = aggregate_source(@prepared[id], options)
            source.values_at(*options[:group_keys]) == group_key
          end
          return @aggregate_order.size unless anchor

          @aggregate_order.index do |existing_key|
            existing_anchor = visible_order.index do |id|
              source = aggregate_source(@prepared[id], options)
              source.values_at(*options[:group_keys]) == existing_key
            end
            existing_anchor && existing_anchor > anchor
          end || @aggregate_order.size
        end

        def aggregate_source(row, options)
          return row if options[:group_keys].include?(id_key)

          row.reject { |key, _| key == id_key }
        end

        def add_sum_values(bucket, row, options)
          options[:sum_mapping].each do |output_key, source_key|
            value = row[source_key]
            bucket[:sums][output_key] += aggregate_numeric_value(value, source_key)
          end
        end

        def subtract_sum_values(bucket, row, options)
          options[:sum_mapping].each do |output_key, source_key|
            value = aggregate_numeric_value(row[source_key], source_key)
            bucket[:sums][output_key] -= value
          end
        end

        def aggregate_numeric_value(value, source_key)
          return 0 if value.nil?
          return value if value.is_a?(Numeric)

          raise TypeError,
                "cannot sum non-numeric value #{value.inspect} for #{source_key.inspect}"
        end

        def snapshot
          @result.map { |row| deep_dup(row) }
        end

        def diff(before)
          if compiler.terminal?
            terminal_diff(before, @result)
          else
            row_diff(before, @result)
          end
        end

        def row_diff(before, after)
          before_rows = index_rows(before)
          after_rows = index_rows(after)

          inserted = after.select { |row| !before_rows.key?(row[id_key]) }
          deleted = before.select { |row| !after_rows.key?(row[id_key]) }
          updated = after.select do |row|
            previous = before_rows[row[id_key]]
            previous && previous != row
          end

          {inserted: inserted, updated: updated, deleted: deleted}
        end

        def terminal_diff(before, after)
          before_rows = index_terminal_rows(before)
          after_rows = index_terminal_rows(after)

          inserted = after.select { |row| !before_rows.key?(terminal_identity(row)) }
          deleted = before.select { |row| !after_rows.key?(terminal_identity(row)) }
          updated = after.select do |row|
            previous = before_rows[terminal_identity(row)]
            previous && previous != row
          end

          {inserted: inserted, updated: updated, deleted: deleted}
        end

        def index_rows(rows)
          rows.to_h { |row| [row[id_key], row] }
        end

        def index_terminal_rows(rows)
          rows.to_h { |row| [terminal_identity(row), row] }
        end

        def terminal_identity(row)
          if compiler.terminal.first == :group
            options = compiler.group_options
            row.reject { |key, _| key == options[:key] }
          else
            options = compiler.aggregate_options
            options[:measure_keys].each_with_object(row.dup) { |key, identity|
              identity.delete(key)
            }
          end
        end

        def deep_dup(value)
          case value
          when Hash then value.to_h { |key, item| [deep_dup(key), deep_dup(item)] }
          when Array then value.map { |item| deep_dup(item) }
          else value
          end
        end

        def raise_invalid(message)
          raise InvalidEventError, message
        end
      end
    end
  end
end
