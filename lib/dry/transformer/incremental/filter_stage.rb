# frozen_string_literal: true

module Dry
  module Transformer
    module Incremental
      # Per-row filtering stage. Incremental by construction: membership of
      # each row is re-evaluated only when that row changes. Rows that enter
      # or leave the result set are emitted as additions and removals.
      #
      # @api private
      class FilterStage
        # @api private
        def initialize(predicate)
          @predicate = predicate
          @passed = {}
        end

        # @api private
        def incremental?
          true
        end

        # @api private
        def description
          "filter"
        end

        # Full, pure execution over [id, row] pairs
        #
        # @api private
        def run(pairs)
          pairs.select { |(_id, row)| @predicate.call(row) }
        end

        # Incremental execution over row events
        #
        # @api private
        def process(events)
          events.flat_map do |event|
            type, id = event

            case type
            when :add
              row = event[2]
              if @predicate.call(row)
                @passed[id] = row
                [[:add, id, row]]
              else
                []
              end
            when :remove
              row = @passed.delete(id)
              row ? [[:remove, id, row]] : []
            when :update
              update(id, event[3])
            end
          end
        end

        private

        # @api private
        def update(id, new_row)
          was = @passed.key?(id)
          passes = @predicate.call(new_row)

          if was && passes
            old = @passed[id]
            @passed[id] = new_row
            [[:update, id, old, new_row]]
          elsif was
            old = @passed.delete(id)
            [[:remove, id, old]]
          elsif passes
            @passed[id] = new_row
            [[:add, id, new_row]]
          else
            []
          end
        end
      end
    end
  end
end
