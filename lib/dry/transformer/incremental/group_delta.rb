# frozen_string_literal: true

module Dry
  module Transformer
    module Incremental
      # Delta of a grouped (aggregated) pipeline output, relative to the
      # previous result. Entries are keyed by group key.
      #
      # @api public
      class GroupDelta
        # @return [Hash{Object => Hash}] groups that appeared, keyed by group key
        attr_reader :added

        # @return [Hash{Object => Hash}] groups that became empty, keyed by group key
        attr_reader :removed

        # @return [Hash{Object => Array(Hash, Hash)}] group key => [before, after]
        attr_reader :changed

        # @api private
        def initialize(added: {}, removed: {}, changed: {})
          @added = added
          @removed = removed
          @changed = changed
        end

        # @api public
        def empty?
          added.empty? && removed.empty? && changed.empty?
        end

        # @api public
        def to_h
          {added: added, removed: removed, changed: changed}
        end

        # @api public
        def ==(other)
          other.is_a?(GroupDelta) && to_h == other.to_h
        end
        alias_method :eql?, :==
      end
    end
  end
end
