# frozen_string_literal: true

module Dry
  module Transformer
    # Offline transformations used before exporting test data.
    #
    # @api public
    module PrivacyTransformations
      extend Registry

      # k-anonymize a table through full-domain generalization.
      #
      # Each quasi-identifier column is generalized at one globally consistent
      # level. Rows whose generalized equivalence class is smaller than `k`
      # are suppressed, as long as their share stays within the suppression
      # budget. Sensitive columns are carried through untouched and never take
      # part in grouping.
      #
      # @example categorical and numeric quasi-identifiers
      #   fn = Dry::Transformer::PrivacyTransformations[:k_anonymize,
      #     k: 3,
      #     quasi_identifiers: [
      #       {key: :city, type: :categorical, tree: {
      #         "Europe" => {"France" => {"Paris" => nil}, "Germany" => {"Berlin" => nil}}
      #       }},
      #       {key: :age, type: :numeric, ranges: [[20..29, 30..39], [20..39]]}
      #     ],
      #     max_suppression: 0.1
      #   ]
      #
      #   result = fn.call(rows)
      #   result.rows            # released rows with generalized values
      #   result.suppressed_rows # rows removed from the release
      #   result.loss            # average information loss
      #   result.proven_optimal  # false if the budget cut the search short
      #
      # @param [Array<Hash>] rows Table rows (tuples)
      # @param [Hash] options
      # @option options [Integer] :k Minimum equivalence class size
      # @option options [Array<Hash>] :quasi_identifiers Hierarchy specs
      # @option options [Float] :max_suppression Maximum suppressed share
      # @option options [Integer, nil] :budget Max schemes to evaluate
      #
      # @return [Dry::Transformer::KAnonymity::Result]
      #
      # @api public
      def self.k_anonymize(rows, options = {})
        k = options.fetch(:k)
        quasi_identifiers = options.fetch(:quasi_identifiers)
        max_suppression = options.fetch(:max_suppression, 0.0)
        budget = options[:budget]

        unless rows.is_a?(::Array)
          raise ArgumentError, "k_anonymize expects an array of tuples"
        end

        unless k.is_a?(::Integer) && k >= 1
          raise ArgumentError, "k must be a positive integer"
        end

        unless max_suppression.is_a?(::Numeric) &&
               max_suppression.between?(0, 1)
          raise ArgumentError, "max_suppression must be between 0 and 1"
        end

        if budget && !(budget.is_a?(::Integer) && budget >= 1)
          raise ArgumentError, "budget must be nil or a positive integer"
        end

        unless quasi_identifiers.is_a?(::Array) && !quasi_identifiers.empty?
          raise ArgumentError, "quasi_identifiers must list at least one column"
        end

        keys = quasi_identifiers.map { |spec| spec[:key] }
        if keys.uniq.size != keys.size
          raise ArgumentError, "quasi-identifier columns must be unique"
        end

        hierarchies = quasi_identifiers.map do |spec|
          KAnonymity::Hierarchy.build(spec)
        end

        KAnonymity::Solver
          .new(rows, hierarchies, k: k, max_suppression: max_suppression, budget: budget)
          .call
      end
    end
  end
end
