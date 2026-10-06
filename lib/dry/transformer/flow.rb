# frozen_string_literal: true

module Dry
  module Transformer
    # Fused streaming execution for collection transformations.
    #
    # @api public
    class Flow
      NORMAL_COMPLETION = Object.new.freeze

      # Signal that a reduction should stop before consuming more input.
      #
      # @api public
      class Reduced
        # @return [Object]
        attr_reader :value

        # @api private
        def initialize(value)
          @value = value
        end

        def reduced?
          true
        end
      end

      UnsupportedTransformationError = Class.new(Error)

      # @api private
      class Reduction
        def initialize(initial, step, completion = nil)
          @initial = initial
          @step = step
          @completion = completion
        end

        def start
          @initial
        end

        def call(accumulator, value)
          @step.call(accumulator, value)
        end

        def complete(accumulator)
          @completion ? @completion.call(accumulator) : accumulator
        end
      end

      # @api private
      class ProtocolReduction
        def initialize(reducer)
          @reducer = reducer
        end

        def start
          @reducer.init
        end

        def call(accumulator, value)
          @reducer.call(accumulator, value)
        end

        def complete(accumulator)
          if @reducer.respond_to?(:complete)
            @reducer.complete(accumulator)
          elsif @reducer.respond_to?(:final)
            @reducer.final(accumulator)
          elsif @reducer.respond_to?(:finish)
            @reducer.finish(accumulator)
          else
            accumulator
          end
        end
      end

      class Stage; end

      # @api private
      class Map < Stage
        def initialize(fn)
          @fn = fn
        end

        def call(downstream)
          fn = @fn
          Step.new(downstream) { |accumulator, value|
            downstream.call(accumulator, fn.call(value))
          }
        end
      end

      # @api private
      class Filter < Stage
        def initialize(fn)
          @fn = fn
        end

        def call(downstream)
          fn = @fn
          Step.new(downstream) { |accumulator, value|
            next accumulator unless fn.call(value)

            downstream.call(accumulator, value)
          }
        end
      end

      # @api private
      class FlatMap < Stage
        def initialize(fn)
          @fn = fn
        end

        def call(downstream)
          FlatMapStep.new(@fn, downstream)
        end
      end

      # @api private
      class FlatMapStep
        def initialize(fn, downstream)
          @fn = fn
          @downstream = downstream
        end

        def start
          @downstream.start
        end

        def call(accumulator, value)
          emitted = @fn.call(value)

          unless emitted.is_a?(Array)
            return @downstream.call(accumulator, emitted)
          end

          emitted.each do |item|
            accumulator = @downstream.call(accumulator, item)
            break accumulator if Flow.reduced?(accumulator)
          end

          accumulator
        end

        def complete(accumulator)
          return accumulator if Flow.reduced?(accumulator)

          @downstream.complete(accumulator)
        end
      end

      # @api private
      class Take < Stage
        def initialize(count)
          unless count.is_a?(Integer) && count >= 0
            raise ArgumentError, "take count must be a non-negative integer"
          end

          @count = count
        end

        def call(downstream)
          TakeStep.new(@count, downstream)
        end
      end

      # @api private
      class TakeStep
        def initialize(count, downstream)
          @remaining = count
          @downstream = downstream
        end

        def start
          accumulator = @downstream.start
          return accumulator unless @remaining.zero?

          Reduced.new(accumulator)
        end

        def call(accumulator, value)
          accumulator = @downstream.call(accumulator, value)
          @remaining -= 1
          return accumulator unless @remaining.zero?

          Reduced.new(Flow.unreduced(accumulator))
        end

        def complete(accumulator)
          return accumulator if Flow.reduced?(accumulator)

          @downstream.complete(accumulator)
        end
      end

      # @api private
      class Partition < Stage
        def initialize(size)
          unless size.is_a?(Integer) && size >= 1
            raise ArgumentError, "partition size must be greater than zero"
          end

          @size = size
        end

        def call(downstream)
          PartitionStep.new(@size, downstream)
        end
      end

      # @api private
      class PartitionStep
        def initialize(size, downstream)
          @size = size
          @downstream = downstream
          @buffer = []
        end

        def start
          @downstream.start
        end

        def call(accumulator, value)
          @buffer << value
          return accumulator unless @buffer.size == @size

          group = @buffer
          @buffer = []
          @downstream.call(accumulator, group)
        end

        def complete(accumulator)
          unless @buffer.empty?
            group = @buffer
            @buffer = []
            accumulator = @downstream.call(accumulator, group)
            return accumulator if Flow.reduced?(accumulator)
          end

          @downstream.complete(accumulator)
        end
      end

      # @api private
      class Step
        def initialize(downstream, &step)
          @downstream = downstream
          @step = step
        end

        def start
          @downstream.start
        end

        def call(accumulator, value)
          @step.call(accumulator, value)
        end

        def complete(accumulator)
          return accumulator if Flow.reduced?(accumulator)

          @downstream.complete(accumulator)
        end
      end

      def self.reduced(value)
        Reduced.new(value)
      end

      def self.reduced?(value)
        return true if value.is_a?(Reduced)

        value.respond_to?(:reduced?) && value.reduced?.equal?(true)
      end

      def self.unreduced(value)
        reduced?(value) ? value.value : value
      end

      def self.[](pipeline)
        new(stages_for(pipeline))
      end

      def self.transduce(pipeline, source, reducer = Undefined, initial = Undefined, &block)
        self[pipeline].transduce(source, reducer, initial, &block)
      end

      class << self
        alias_method :stream, :transduce
        alias_method :call, :transduce
      end

      def self.stages_for(pipeline)
        case pipeline
        when Composite
          stages_for(pipeline.left) + stages_for(pipeline.right)
        when Function
          [stage_for(pipeline)]
        else
          raise UnsupportedTransformationError, "only composed transformations can be streamed"
        end
      end

      def self.stage_for(function)
        argument = function.args.first

        case function.name
        when :map, :map_array
          Map.new(argument)
        when :filter
          Filter.new(argument)
        when :flat_map
          FlatMap.new(argument)
        when :take
          Take.new(argument)
        when :partition
          Partition.new(argument)
        else
          raise UnsupportedTransformationError,
                "#{function.name.inspect} cannot be fused into a streaming pipeline"
        end
      end

      def initialize(stages)
        @stages = stages
      end

      def transduce(source, reducer = Undefined, initial = Undefined, &block)
        reduction = build_reduction(reducer, initial, block)
        process = @stages.reverse.reduce(reduction) { |downstream, stage|
          stage.call(downstream)
        }
        source = Array(source) unless source.is_a?(Enumerable)

        accumulator = process.start
        return Flow.unreduced(accumulator) if Flow.reduced?(accumulator)

        completion =
          catch(:break) do
            source.each do |value|
              accumulator = process.call(accumulator, value)

              if Flow.reduced?(accumulator)
                throw(:break, accumulator)
              end
            end

            NORMAL_COMPLETION
          end

        if completion.equal?(NORMAL_COMPLETION)
          Flow.unreduced(process.complete(accumulator))
        else
          Flow.unreduced(completion.nil? ? accumulator : completion)
        end
      end

      alias_method :stream, :transduce

      private

      def build_reduction(reducer, initial, block)
        if block
          initial = reducer.equal?(Undefined) ? nil : reducer
          Reduction.new(initial, block)
        elsif reducer.equal?(Undefined)
          Reduction.new([], ->(accumulator, value) { accumulator << value })
        elsif reducer.is_a?(Symbol)
          initial = [] if initial.equal?(Undefined)
          Reduction.new(initial, ->(accumulator, value) { accumulator.public_send(reducer, value) })
        elsif reducer.respond_to?(:init)
          ProtocolReduction.new(reducer)
        elsif reducer.respond_to?(:call)
          initial = nil if initial.equal?(Undefined)
          Reduction.new(initial, reducer)
        else
          raise ArgumentError, "a reducer must respond to #call, #init, or be a block"
        end
      end
    end
  end
end
