# frozen_string_literal: true

module Dry
  module Transformer
    module KAnonymity
      # Base contract for quasi-identifier generalization hierarchies.
      #
      # A hierarchy describes, for every level from `0` (raw values) up to
      # `levels`, how values of one column are generalized. The same level is
      # always applied globally to every row (full-domain generalization).
      #
      # @api private
      class Hierarchy
        # Name of the quasi-identifier column in the input tuples
        #
        # @return [Object]
        #
        # @api private
        attr_reader :key

        # Highest generalization level (inclusive)
        #
        # @return [Integer]
        #
        # @api private
        attr_reader :levels

        # Builds a hierarchy from a caller supplied specification.
        #
        # @param [Hash] config
        # @option config [Object] :key Column name in the input tuples
        # @option config [Symbol] :type Either `:categorical` or `:numeric`
        #
        # @return [Hierarchy]
        #
        # @api private
        def self.build(config)
          cfg = config.dup
          key = cfg.delete(:key)
          type = cfg.delete(:type)

          if key.nil?
            raise ArgumentError, "quasi-identifier hierarchy is missing :key"
          end

          case type
          when :categorical
            CategoricalHierarchy.new(key, cfg.fetch(:tree))
          when :numeric
            NumericHierarchy.new(key, cfg.fetch(:ranges))
          when nil
            raise ArgumentError, "hierarchy for #{key.inspect} is missing :type"
          else
            raise ArgumentError, "unknown hierarchy type #{type.inspect} for #{key.inspect}"
          end
        end

        # Generalized representation of `value` at `level`
        #
        # Missing values (`nil`) are preserved as `nil` at every level so
        # that they form their own, never generalized, equivalence classes.
        #
        # @return [Object]
        #
        # @api private
        def generalize(value, level)
          return nil if value.nil?

          raise ArgumentError, "level must be between 0 and #{levels}" unless
            level.between?(0, levels)

          generalize_present(value, level)
        end

        # Information loss in `[0, 1]` for `value` generalized at `level`
        #
        # @return [Float]
        #
        # @api private
        def loss(value, level)
          return 0.0 if value.nil?

          loss_present(value, level)
        end
      end
    end
  end
end
