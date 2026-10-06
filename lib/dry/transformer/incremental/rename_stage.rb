# frozen_string_literal: true

module Dry
  module Transformer
    module Incremental
      # Key-renaming stage. A special case of per-row mapping with a
      # declarative key mapping.
      #
      # @api private
      class RenameStage < MapStage
        # @api private
        def initialize(mapping)
          fn = lambda do |row|
            renamed = row.dup
            mapping.each do |from, to|
              renamed[to] = renamed.delete(from) if renamed.key?(from)
            end
            renamed
          end

          super(fn)
        end

        # @api private
        def description
          "rename"
        end
      end
    end
  end
end
