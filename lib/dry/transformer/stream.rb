# frozen_string_literal: true

module Dry
  module Transformer
    module Stream
      extend self

      OPERATIONS = %i[
        map map_array
        filter filter_array select select_array
        flat_map flat_map_array
        take take_array
        partition partition_array
      ].freeze

      Reduced = ::Class.new do
        attr_reader :value

        def initialize(value)
          @value = value
        end
      end

      Halt = ::Class.new do
        attr_reader :value

        def initialize(value)
          @value = value
        end
      end

      class Reducer
        def initialize(reducer, initial = Undefined)
          @reducer = reducer
          @initial = initial
        end

        def init
          return @initial unless @initial.equal?(Undefined)
          return @reducer.init if @reducer.respond_to?(:init)

          []
        end

        def call(accumulator, value)
          @reducer.call(accumulator, value)
        end

        def complete(accumulator)
          reduced = reduced?(accumulator)
          result = @reducer.complete(unreduce(accumulator)) if @reducer.respond_to?(:complete)
          result ||= unreduce(accumulator)

          return result if reduced?(result)

          reduced ? Reduced.new(result) : result
        end

        private

        def reduced?(value)
          Stream.reduced?(value)
        end

        def unreduce(value)
          Stream.value(value)
        end
      end

      class Transducer
        attr_reader :downstream

        def initialize(downstream)
          @downstream = downstream
        end

        def init
          downstream.init
        end

        def call(accumulator, _value)
          accumulator
        end

        def complete(accumulator)
          downstream.complete(accumulator)
        end

        private

        def reduced?(value)
          Stream.reduced?(value)
        end

        def value(value)
          Stream.value(value)
        end
      end

      class Map < Transducer
        def initialize(downstream, function)
          super(downstream)
          @function = function
        end

        def call(accumulator, value)
          return accumulator if reduced?(accumulator)

          downstream.call(accumulator, @function.call(value))
        end
      end

      class Filter < Transducer
        def initialize(downstream, function)
          super(downstream)
          @function = function
        end

        def call(accumulator, value)
          return accumulator if reduced?(accumulator)
          return accumulator unless @function.call(value)

          downstream.call(accumulator, value)
        end
      end

      class FlatMap < Transducer
        def initialize(downstream, function)
          super(downstream)
          @function = function
        end

        def call(accumulator, value)
          return accumulator if reduced?(accumulator)

          @function.call(value).each do |mapped_value|
            accumulator = downstream.call(accumulator, mapped_value)
            break if reduced?(accumulator)
          end

          accumulator
        end
      end

      class Take < Transducer
        def initialize(downstream, count)
          super(downstream)
          @remaining = count
        end

        def init
          initial = super
          return Reduced.new(initial) if @remaining <= 0

          initial
        end

        def call(accumulator, value)
          return accumulator if reduced?(accumulator)
          return Reduced.new(accumulator) if @remaining <= 0

          @remaining -= 1
          result = downstream.call(accumulator, value)
          return Reduced.new(value(result)) if @remaining <= 0

          result
        end
      end

      class Partition < Transducer
        def initialize(downstream, size)
          super(downstream)
          @size = size
          @buffer = []
        end

        def call(accumulator, value)
          return accumulator if reduced?(accumulator)

          @buffer << value
          return accumulator unless @buffer.size == @size

          partition = @buffer.dup
          @buffer = []
          downstream.call(accumulator, partition)
        end

        def complete(accumulator)
          return complete_reduced(accumulator) if reduced?(accumulator)

          result = accumulator
          unless @buffer.empty?
            result = downstream.call(accumulator, @buffer)
            @buffer = []
            if reduced?(result)
              return complete_reduced(result)
            end
          end

          downstream.complete(result)
        end

        private

        def complete_reduced(result)
          completed = downstream.complete(result)
          reduced?(completed) ? completed : Reduced.new(completed)
        end
      end

      def self.reduced(value)
        Reduced.new(value)
      end

      def self.halt(value = nil)
        throw :halt, Halt.new(value)
      end

      def self.reduced?(value)
        value.is_a?(Reduced)
      end

      def self.value(value)
        reduced?(value) ? value.value : value
      end

      def transduce(
        pipeline,
        source,
        reducer = Undefined,
        initial = Undefined,
        init: Undefined,
        &block
      )
        if block
          initial = reducer unless reducer.equal?(Undefined)
          reducer = block
        else
          reducer = nil if reducer.equal?(Undefined)
        end

        initial = init unless init.equal?(Undefined)
        fused, remaining = split(functions(pipeline))

        if remaining.any? && (reducer || !initial.equal?(Undefined))
          raise UnsupportedOperationError, remaining.first.name
        end

        return call_remaining(fused, remaining, source) if remaining.any?

        run(fused, source, Reducer.new(reducer || method(:append), initial))
      end

      private

      def build(pipeline, reducer)
        all_functions = pipeline.is_a?(Array) ? pipeline : functions(pipeline)
        all_functions.reverse.reduce(reducer) do |downstream, function|
          transducer(function, downstream)
        end
      end

      def functions(function, functions = [])
        case function
        when Composite
          functions(function.left, functions)
          functions(function.right, functions)
        when Function
          functions << function
        end

        functions
      end

      def transducer(function, downstream)
        argument = function.args.first

        case function.name
        when :map, :map_array
          Map.new(downstream, argument)
        when :filter, :filter_array, :select, :select_array
          Filter.new(downstream, argument)
        when :flat_map, :flat_map_array
          FlatMap.new(downstream, argument)
        when :take, :take_array
          Take.new(downstream, argument)
        when :partition, :partition_array
          Partition.new(downstream, argument)
        else
          raise UnsupportedOperationError, function.name
        end
      end

      def supported?(function)
        OPERATIONS.include?(function.name)
      end

      def split(all_functions)
        unsupported_index = all_functions.index { |function| !supported?(function) }
        return [all_functions, []] unless unsupported_index

        prefix = all_functions[0...unsupported_index]
        suffix = all_functions[unsupported_index..]

        if suffix[1..].any? { |function| supported?(function) }
          raise UnsupportedOperationError, suffix[1..].find { |function| supported?(function) }.name
        end

        [prefix, suffix]
      end

      def run(pipeline, input, reducer)
        runner = build(pipeline, reducer)
        accumulator = runner.init
        unless reduced?(accumulator)
          enumerable = input.respond_to?(:each) ? input : Array(input)
          enumerable.each do |value|
            result = catch(:halt) { runner.call(accumulator, value) }
            result = Reduced.new(result.value) if result.instance_of?(Halt)

            accumulator = result
            break if reduced?(accumulator)
          end
        end

        result = runner.complete(accumulator)
        reduced?(result) ? result.value : result
      end

      def call_remaining(prefix, suffix, input)
        result = run(prefix, input, Reducer.new(method(:append)))
        suffix.reduce(result) { |value, function| function.call(value) }
      end

      def append(accumulator, value)
        accumulator + [value]
      end

      UnsupportedOperationError = ::Class.new(Error) do
        def initialize(name)
          super("#{name.inspect} cannot be fused into a stream")
        end
      end
    end
  end
end
