# frozen_string_literal: true

module Dry
  module Transformer
    module KAnonymity
      # Outcome of a k-anonymization run.
      #
      # @api private
      class Result
        # @api private
        def initialize(attributes)
          @attributes = attributes
        end

        # Generalization level applied to each quasi-identifier column
        #
        # @return [Hash{Object => Integer}, nil]
        #
        # @api public
        def levels
          @attributes[:levels]
        end

        # Released rows (original order), quasi-identifiers generalized
        #
        # @return [Array<Hash>]
        #
        # @api public
        def rows
          @attributes[:rows]
        end

        # One entry per input row describing where it ended up
        #
        # Each entry contains `:index`, `:released` (Boolean), `:group_size`,
        # `:group` (generalized quasi-identifier signature) and `:loss`.
        #
        # @return [Array<Hash>]
        #
        # @api public
        def destinations
          @attributes[:destinations]
        end

        # Input rows removed by suppression, in their original order
        #
        # @return [Array<Hash>]
        #
        # @api public
        def suppressed_rows
          @attributes[:suppressed_rows]
        end

        # Number of suppressed rows
        #
        # @return [Integer]
        #
        # @api public
        def suppressed_count
          @attributes[:suppressed_count]
        end

        # Share of rows suppressed, in `[0, 1]`
        #
        # @return [Float]
        #
        # @api public
        def suppression_rate
          @attributes[:suppression_rate]
        end

        # Average per-row information loss over all input rows
        #
        # Suppressed rows contribute a loss of `1`. Missing values never add
        # loss. Equals `1.0` when no feasible scheme exists.
        #
        # @return [Float]
        #
        # @api public
        def loss
          @attributes[:loss]
        end

        # Whether a scheme satisfying `k` and the suppression budget was found
        #
        # @return [Boolean]
        #
        # @api public
        def feasible
          @attributes[:feasible]
        end
        alias_method :feasible?, :feasible

        # Whether the returned scheme was proven optimal
        #
        # `false` when the evaluation budget was exhausted before every
        # candidate scheme was checked.
        #
        # @return [Boolean]
        #
        # @api public
        def proven_optimal
          @attributes[:proven_optimal]
        end
        alias_method :proven_optimal?, :proven_optimal

        # Number of candidate schemes actually evaluated
        #
        # @return [Integer]
        #
        # @api public
        def evaluations
          @attributes[:evaluations]
        end

        # Total number of candidate schemes in the search space
        #
        # @return [Integer]
        #
        # @api public
        def total_schemes
          @attributes[:total_schemes]
        end

        # @return [Hash]
        #
        # @api public
        def to_h
          @attributes.dup
        end
      end
    end
  end
end
