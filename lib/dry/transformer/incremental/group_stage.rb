# frozen_string_literal: true

module Dry
  module Transformer
    module Incremental
      # Terminal grouping stage with retractable aggregations (sum / count).
      #
      # Incrementally maintains one aggregate value per group by adding each
      # row's contribution when it enters a group and retracting it when it
      # leaves. A single update can therefore touch two groups: the row is
      # retracted from its old group and added to its new one. Groups whose
      # membership drops to zero are removed from the output.
      #
      # Rows are tracked per id, so rows with identical content but different
      # ids contribute independently and are never merged.
      #
      # Emits group-level events of the form [:set, key, value] where a nil
      # value means the group disappeared.
      #
      # @api private
      class GroupStage
        # Sum aggregation over a row attribute. Retractable.
        #
        # @api private
        class SumAggregation
          # @api private
          attr_reader :name

          # @api private
          def initialize(attribute, name: nil)
            @attribute = attribute
            @name = name || :"sum_#{attribute}"
          end

          # @api private
          def retractable?
            true
          end

          # @api private
          def zero
            0
          end

          # @api private
          def add(value, row)
            value + (row[@attribute] || 0)
          end

          # @api private
          def retract(value, row)
            value - (row[@attribute] || 0)
          end

          # @api private
          def compute(rows)
            rows.sum { |row| row[@attribute] || 0 }
          end
        end

        # Row count aggregation. Retractable.
        #
        # @api private
        class CountAggregation
          # @api private
          attr_reader :name

          # @api private
          def initialize(name: :count)
            @name = name
          end

          # @api private
          def retractable?
            true
          end

          # @api private
          def zero
            0
          end

          # @api private
          def add(value, _row)
            value + 1
          end

          # @api private
          def retract(value, _row)
            value - 1
          end

          # @api private
          def compute(rows)
            rows.size
          end
        end

        # Generic aggregation computed via +public_send+ over the collected
        # attribute values (e.g. :max). Not retractable, so it cannot be
        # maintained incrementally; a session either rejects it or falls back
        # to full recomputation.
        #
        # @api private
        class GenericAggregation
          # @api private
          attr_reader :name

          # @api private
          def initialize(function, attribute, name: nil)
            @function = function
            @attribute = attribute
            @name = name || :"#{function}_#{attribute}"
          end

          # @api private
          def retractable?
            false
          end

          # @api private
          def compute(rows)
            rows.map { |row| row[@attribute] }.public_send(@function)
          end
        end

        # @api private
        attr_reader :keys

        # @api private
        attr_reader :aggregations

        # @api private
        def initialize(keys, aggregations)
          raise ArgumentError, "group requires at least one key" if keys.empty?

          @keys = keys
          @aggregations = aggregations
          @sizes = Hash.new(0)
          @groups = {}
        end

        # @api private
        def incremental?
          aggregations.all?(&:retractable?)
        end

        # @api private
        def description
          names = aggregations.map(&:name).join(", ")
          "group(#{keys.join(', ')}) with #{names}"
        end

        # Full, pure execution over [id, row] pairs
        #
        # @api private
        def run(pairs)
          pairs.group_by { |(_id, row)| group_key(row) }.to_h do |key, members|
            rows = members.map(&:last)
            [key, aggregations.to_h { |agg| [agg.name, agg.compute(rows)] }]
          end
        end

        # Incremental execution over row events
        #
        # @api private
        def process(events)
          events.flat_map do |event|
            case event[0]
            when :add then add_row(event[2])
            when :remove then remove_row(event[2])
            when :update then remove_row(event[2]) + add_row(event[3])
            end
          end
        end

        private

        # @api private
        def add_row(row)
          key = group_key(row)
          @sizes[key] += 1
          acc = @groups[key] ||= aggregations.to_h { |agg| [agg.name, agg.zero] }
          aggregations.each { |agg| acc[agg.name] = agg.add(acc[agg.name], row) }
          [[:set, key, acc.dup]]
        end

        # @api private
        def remove_row(row)
          key = group_key(row)
          @sizes[key] -= 1
          acc = @groups[key]
          aggregations.each { |agg| acc[agg.name] = agg.retract(acc[agg.name], row) }

          if @sizes[key].zero?
            @sizes.delete(key)
            @groups.delete(key)
            [[:set, key, nil]]
          else
            [[:set, key, acc.dup]]
          end
        end

        # @api private
        def group_key(row)
          keys.length == 1 ? row[keys.first] : row.values_at(*keys)
        end
      end
    end
  end
end
