# frozen_string_literal: true

module Dry
  module Transformer
    module Incremental
      # Per-row mapping stage. Incremental by construction: only changed rows
      # are re-mapped. The mapped output of every live row is cached by id so
      # removals and updates can be propagated without recomputation.
      #
      # @api private
      class MapStage
        # @api private
        def initialize(fn)
          @fn = fn
          @cache = {}
        end

        # @api private
        def incremental?
          true
        end

        # @api private
        def description
          "map"
        end

        # Full, pure execution over [id, row] pairs
        #
        # @api private
        def run(pairs)
          pairs.map { |id, row| [id, @fn.call(row)] }
        end

        # Incremental execution over row events
        #
        # @api private
        def process(events)
          events.map do |event|
            type, id = event

            case type
            when :add
              output = @fn.call(event[2])
              @cache[id] = output
              [:add, id, output]
            when :remove
              [:remove, id, @cache.delete(id)]
            when :update
              old = @cache[id]
              output = @fn.call(event[3])
              @cache[id] = output
              [:update, id, old, output]
            end
          end
        end
      end
    end
  end
end
