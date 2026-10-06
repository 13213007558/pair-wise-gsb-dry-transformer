# frozen_string_literal: true

module Dry
  module Transformer
    module Incremental
      # Declarative DSL for describing an incremental pipeline.
      #
      # Only transformations with derivable incremental rules can be
      # declared here: per-row +map+ / +filter+ / +rename+ and a terminal
      # +group+ with retractable aggregations. Arbitrary collection-level
      # procs are rejected via #transform.
      #
      # @api public
      class Builder
        # @api private
        attr_reader :stages

        # @api private
        def initialize
          @stages = []
          @sealed = false
        end

        # Per-row mapping. The callable is applied to each changed row only.
        #
        # @api public
        def map(fn = nil, &block)
          callable = fn || block
          raise ArgumentError, 'map requires a callable or a block' unless callable

          append(MapStage.new(callable))
        end

        # Per-row filtering. The predicate is re-evaluated for changed rows
        # only; rows entering or leaving the result set become additions and
        # removals.
        #
        # @api public
        def filter(predicate = nil, &block)
          callable = predicate || block
          raise ArgumentError, 'filter requires a callable or a block' unless callable

          append(FilterStage.new(callable))
        end

        # Rename hash keys of every row.
        #
        # @api public
        def rename(mapping)
          append(RenameStage.new(mapping))
        end

        # Terminal grouping stage with retractable aggregations.
        #
        #   t.group(:city) do |g|
        #     g.sum :amount
        #     g.count
        #   end
        #
        # @api public
        def group(keys)
          aggregation_builder = AggregationBuilder.new
          yield aggregation_builder
          if aggregation_builder.aggregations.empty?
            raise ArgumentError, 'group requires at least one aggregation'
          end

          append(GroupStage.new(Array(keys), aggregation_builder.aggregations))
          @sealed = true
        end

        # Arbitrary collection-level procs have no derivable incremental
        # rules and are always rejected.
        #
        # @api public
        def transform(_fn = nil, &_block)
          raise UnsupportedTransformError,
                'arbitrary collection-level procs cannot be maintained incrementally; ' \
                'use per-row #map/#filter or a grouped sum/count aggregation instead'
        end

        private

        # @api private
        def append(stage)
          raise Error, 'no stages can follow a group stage' if @sealed

          @stages << stage
        end
      end
    end
  end
end
