# frozen_string_literal: true

module Dry
  module Transformer
    module Incremental
      # An ordered list of incremental stages built by {Builder}.
      #
      # @api private
      class Pipeline
        # @api private
        attr_reader :stages

        # @api private
        def initialize(stages)
          @stages = stages.freeze
        end

        # Whether every stage has derivable incremental rules
        #
        # @api private
        def incremental?
          stages.all?(&:incremental?)
        end

        # Whether the pipeline ends in a grouping stage
        #
        # @api private
        def grouped?
          !stages.empty? && stages.last.is_a?(GroupStage)
        end

        # Full execution over [id, row] pairs. Returns pairs for
        # row-oriented pipelines and a groups hash for grouped ones.
        #
        # @api private
        def run(pairs)
          stages.reduce(pairs) { |input, stage| stage.run(input) }
        end

        # @api private
        def unsupported_description
          stages.reject(&:incremental?).map(&:description).join(', ')
        end
      end
    end
  end
end
