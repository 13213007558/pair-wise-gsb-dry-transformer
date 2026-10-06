# frozen_string_literal: true

module Dry
  module Transformer
    module Incremental
      # Maintains the result of a declarative pipeline over a collection of
      # rows with stable ids, consuming add / remove / update events and
      # returning a delta relative to the previous result on every #apply.
      #
      # Events are hashes:
      #
      #   {type: :add, row: {id: 1, ...}}
      #   {type: :remove, id: 1}
      #   {type: :update, id: 1, row: {id: 1, ...}}   # full replacement
      #   {type: :update, id: 1, changes: {...}}      # partial merge
      #
      # When the pipeline contains transformations without incremental
      # rules (non-retractable aggregations), the session either raises
      # UnsupportedTransformError (default, +on_unsupported: :raise+) or
      # explicitly degrades to re-executing the whole pipeline and diffing
      # the results (+on_unsupported: :recompute+).
      #
      # @api public
      class Session
        # @api private
        NOT_FOUND = Object.new.freeze
        private_constant :NOT_FOUND

        # @return [Symbol] key holding the stable row id
        attr_reader :id_key

        # @api private
        attr_reader :pipeline

        # @api public
        def initialize(id: :id, on_unsupported: :raise)
          unless %i[raise recompute].include?(on_unsupported)
            raise ArgumentError, 'on_unsupported must be :raise or :recompute'
          end

          @id_key = id
          @on_unsupported = on_unsupported

          builder = Builder.new
          yield builder if block_given?
          @pipeline = Pipeline.new(builder.stages)

          if !pipeline.incremental? && on_unsupported == :raise
            raise UnsupportedTransformError,
                  'pipeline contains transformations without incremental rules: ' \
                  "#{pipeline.unsupported_description}; " \
                  'pass on_unsupported: :recompute to fall back to full recomputation'
          end

          @rows = {}
          @output = {}
        end

        # Whether the session propagates events incrementally (false when it
        # degraded to full recomputation)
        #
        # @api public
        def incremental?
          pipeline.incremental?
        end

        # Current output: {id => row} for row-oriented pipelines,
        # {group_key => {aggregate => value}} for grouped pipelines
        #
        # @api public
        def result
          @output
        end

        # Current input rows, keyed by id
        #
        # @api public
        def input
          @rows.dup
        end

        # Apply a batch of events and return the delta relative to the
        # previous result (RowDelta or GroupDelta)
        #
        # @api public
        def apply(events)
          row_events = Array(events).map { |event| apply_event(event) }

          if incremental?
            propagate(row_events)
          else
            recompute
          end
        end

        private

        # @api private
        def propagate(row_events)
          out_events = pipeline.stages.reduce(row_events) do |events, stage|
            stage.process(events)
          end

          if pipeline.grouped?
            apply_group_events(out_events)
          else
            apply_row_events(out_events)
          end
        end

        # @api private
        def apply_row_events(events)
          before = touched_keys(events) { |event| event[1] }

          events.each do |type, id, a, b|
            case type
            when :add then @output[id] = a
            when :update then @output[id] = b
            when :remove then @output.delete(id)
            end
          end

          added, removed, updated = partition_touched(before)
          RowDelta.new(added: added, removed: removed, updated: updated)
        end

        # @api private
        def apply_group_events(events)
          before = touched_keys(events) { |event| event[1] }

          events.each do |(_type, key, value)|
            if value.nil?
              @output.delete(key)
            else
              @output[key] = value
            end
          end

          added, removed, changed = partition_touched(before)
          GroupDelta.new(added: added, removed: removed, changed: changed)
        end

        # Snapshot the current output value of every key an event batch is
        # about to touch, so the delta can be netted per key
        #
        # @api private
        def touched_keys(events)
          events.each_with_object({}) do |event, touched|
            key = yield event
            touched[key] = @output.fetch(key, NOT_FOUND) unless touched.key?(key)
          end
        end

        # @api private
        def partition_touched(before)
          added = {}
          removed = {}
          changed = {}

          before.each do |key, old|
            new = @output.fetch(key, NOT_FOUND)

            if old.equal?(NOT_FOUND)
              added[key] = new unless new.equal?(NOT_FOUND)
            elsif new.equal?(NOT_FOUND)
              removed[key] = old
            elsif old != new
              changed[key] = [old, new]
            end
          end

          [added, removed, changed]
        end

        # Explicit degradation: re-execute the whole pipeline over the
        # current rows and diff against the previous output
        #
        # @api private
        def recompute
          pairs = @rows.map { |id, row| [id, row] }
          new_output = normalize_output(pipeline.run(pairs))
          old_output = @output
          @output = new_output

          if pipeline.grouped?
            added, removed, changed = diff_outputs(old_output, new_output)
            GroupDelta.new(added: added, removed: removed, changed: changed)
          else
            added, removed, updated = diff_outputs(old_output, new_output)
            RowDelta.new(added: added, removed: removed, updated: updated)
          end
        end

        # @api private
        def diff_outputs(old_output, new_output)
          added = {}
          removed = {}
          changed = {}

          new_output.each do |key, value|
            if !old_output.key?(key)
              added[key] = value
            elsif old_output[key] != value
              changed[key] = [old_output[key], value]
            end
          end
          old_output.each do |key, value|
            removed[key] = value unless new_output.key?(key)
          end

          [added, removed, changed]
        end

        # @api private
        def normalize_output(result)
          pipeline.grouped? ? result : result.to_h
        end

        # Validate an event, apply it to the input rows and return the
        # canonical row event [:add|:remove|:update, id, row, new_row]
        #
        # @api private
        def apply_event(event)
          case event[:type]
          when :add
            row = event.fetch(:row)
            id = row_id(row)
            if @rows.key?(id)
              raise InvalidEventError, "duplicate row id #{id.inspect}"
            end

            @rows[id] = row
            [:add, id, row]
          when :remove
            id = event.fetch(:id)
            row = @rows.delete(id) do
              raise InvalidEventError, "unknown row id #{id.inspect}"
            end
            [:remove, id, row]
          when :update
            id = event.fetch(:id)
            old = @rows.fetch(id) do
              raise InvalidEventError, "unknown row id #{id.inspect}"
            end
            row = updated_row(id, old, event)
            @rows[id] = row
            [:update, id, old, row]
          else
            raise InvalidEventError, "unknown event type #{event[:type].inspect}"
          end
        rescue KeyError => e
          raise InvalidEventError, "malformed event #{event.inspect} (#{e.message})"
        end

        # @api private
        def row_id(row)
          unless row.is_a?(Hash) && row.key?(@id_key)
            raise InvalidEventError, "row is missing id key #{@id_key.inspect}: #{row.inspect}"
          end

          row[@id_key]
        end

        # @api private
        def updated_row(id, old, event)
          if event.key?(:row)
            row = event[:row]
            unless row.is_a?(Hash) && row[@id_key] == id
              raise InvalidEventError, 'updated row must keep its stable id ' \
                                       "#{@id_key.inspect} => #{id.inspect}"
            end

            row
          elsif event.key?(:changes)
            changes = event[:changes]
            if changes.key?(@id_key) && changes[@id_key] != id
              raise InvalidEventError, 'an update cannot change the row id'
            end

            old.merge(changes)
          else
            raise InvalidEventError, 'update event requires :row or :changes'
          end
        end
      end
    end
  end
end
