# frozen_string_literal: true

module Dry
  module Transformer
    module Incremental
      # Collects the aggregations of a +group+ stage.
      #
      # @api public
      class AggregationBuilder
        # @api private
        attr_reader :aggregations

        # @api private
        def initialize
          @aggregations = []
        end

        # Retractable sum over a row attribute. Missing attributes count as 0.
        #
        # @api public
        def sum(attribute, as: nil)
          @aggregations << GroupStage::SumAggregation.new(attribute, name: as)
        end

        # Retractable row count.
        #
        # @api public
        def count(as: :count)
          @aggregations << GroupStage::CountAggregation.new(name: as)
        end

        # Generic aggregation computed via +public_send+ over the collected
        # attribute values (e.g. aggregate(:max, :amount)). Not retractable,
        # so a session either rejects it or falls back to full recomputation.
        #
        # @api public
        def aggregate(function, attribute, as: nil)
          @aggregations << GroupStage::GenericAggregation.new(function, attribute, name: as)
        end
      end
    end
  end
end
