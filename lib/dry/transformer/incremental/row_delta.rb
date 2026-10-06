# frozen_string_literal: true

module Dry
  module Transformer
    module Incremental
      # Delta of a row-oriented pipeline output, relative to the previous
      # result. Rows are keyed by their stable source id.
      #
      # @api public
      class RowDelta
        # @return [Hash{Object => Hash}] rows that appeared, keyed by id
        attr_reader :added

        # @return [Hash{Object => Hash}] rows that disappeared, keyed by id
        attr_reader :removed

        # @return [Hash{Object => Array(Hash, Hash)}] id => [before, after]
        attr_reader :updated

        # @api private
        def initialize(added: {}, removed: {}, updated: {})
          @added = added
          @removed = removed
          @updated = updated
        end

        # @api public
        def empty?
          added.empty? && removed.empty? && updated.empty?
        end

        # @api public
        def to_h
          {added: added, removed: removed, updated: updated}
        end

        # @api public
        def ==(other)
          other.is_a?(RowDelta) && to_h == other.to_h
        end
        alias_method :eql?, :==
      end
    end
  end
end
