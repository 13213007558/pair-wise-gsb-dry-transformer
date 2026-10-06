# frozen_string_literal: true

RSpec.describe Dry::Transformer::Stream do
  let(:array_transformations) { Dry::Transformer::ArrayTransformations }

  describe "streaming operations" do
    let(:pipeline) do
      array_transformations[:filter, -> value { value.odd? }] >>
        array_transformations[:map, -> value { value * 2 }] >>
        array_transformations[:flat_map, -> value { [value, -value] }] >>
        array_transformations[:take, 3]
    end

    it "fuses eager results without reading beyond take" do
      source = CountingEnumerable.new(1..10)
      eager_source = CountingEnumerable.new(1..10)

      eager_pipeline = array_transformations[:filter, -> value { value.odd? }] >>
        array_transformations[:map, -> value { value * 2 }] >>
        array_transformations[:flat_map, -> value { [value, -value] }]

      expect(pipeline.stream(source)).to eql(eager_pipeline.call(eager_source).first(3))
      expect(source.pulls).to be(3)
      expect(source.iterations).to be(1)
    end

    it "does not read the item after take" do
      source = CountingEnumerable.new(1..10)
      pipeline = array_transformations[:filter, -> value { value.odd? }] >>
        array_transformations[:map, -> value { value * 2 }] >>
        array_transformations[:take, 2]

      expect(pipeline.stream(source)).to eql([2, 6])
      expect(source.pulls).to be(3)
    end

    it "does not read anything when take is zero" do
      source = CountingEnumerable.new(1..10)

      expect(array_transformations[:take, 0].stream(source)).to eql([])
      expect(source.pulls).to be(0)
    end

    it "works through a pipe DSL" do
      registry = Module.new do
        extend Dry::Transformer::Registry
        import Dry::Transformer::ArrayTransformations
      end

      transformer = Class.new(Dry::Transformer[registry]) do
        define! do
          filter :odd?.to_proc
          map -> value { value * 2 }
          take 2
        end
      end.new

      expect(transformer.stream(CountingEnumerable.new(1..10))).to eql([2, 6])
    end
  end

  describe "partition" do
    it "flushes the final partition on normal completion" do
      pipeline = array_transformations[:partition, 2]

      expect(pipeline.stream([1, 2, 3])).to eql([[1, 2], [3]])
    end

    it "does not flush a buffered tail after early termination" do
      pipeline = array_transformations[:partition, 2] >>
        array_transformations[:take, 1]

      expect(pipeline.stream([1, 2, 3, 4, 5])).to eql([[1, 2]])
    end

    it "does not emit a buffered tail through later operations" do
      pipeline = array_transformations[:partition, 2] >>
        array_transformations[:map, -> values { values.join }] >>
        array_transformations[:take, 1]

      expect(pipeline.stream(1..5)).to eql(["12"])
    end
  end

  describe "caller reducers" do
    it "passes init, step, and complete to the reducer" do
      reducer = CountingReducer.new
      pipeline = array_transformations[:map, -> value { value * 2 }] >>
        array_transformations[:take, 2]

      expect(pipeline.transduce(1..5, reducer)).to eql(:done => [2, 4])
      expect(reducer.events).to eql(%i[init complete])
    end

    it "supports a block reducer with an initial value" do
      pipeline = array_transformations[:filter, -> value { value.odd? }]

      result = pipeline.transduce(1..6, 0) { |sum, value| sum + value }

      expect(result).to be(9)
    end

    it "respects reducer termination while still calling complete" do
      reducer = EarlyPartitionReducer.new
      pipeline = array_transformations[:partition, 2]

      expect(pipeline.transduce(1..5, reducer)).to eql([[1, 2], :complete])
      expect(reducer.completed).to be(true)
    end

    it "supports throw-halt termination" do
      pipeline = array_transformations[:partition, 2] >>
        array_transformations[:map, -> value { value.join }]

      result = pipeline.transduce(1..5) do |accumulator, value|
        Dry::Transformer::Stream.halt(accumulator) if value == "34"
        accumulator + [value]
      end

      expect(result).to eql(["12"])
    end

    it "does not call complete when a transformation raises" do
      reducer = CountingReducer.new
      pipeline = array_transformations[:map, -> value { raise "boom" if value == 2; value }]

      expect { pipeline.transduce(1..3, reducer) }.to raise_error(RuntimeError, "boom")
      expect(reducer.events).to eql([:init])
    end
  end

  class CountingEnumerable
    include Enumerable

    attr_reader :pulls, :iterations

    def initialize(values)
      @values = values
      @pulls = 0
      @iterations = 0
      @consumed = false
    end

    def each
      raise "enumerable can only be consumed once" if @consumed

      @consumed = true
      @iterations += 1
      @values.each do |value|
        @pulls += 1
        yield value
      end
    end
  end

  class CountingReducer
    attr_reader :events

    def initialize
      @events = []
    end

    def init
      @events << :init
      []
    end

    def call(accumulator, value)
      accumulator + [value]
    end

    def complete(accumulator)
      @events << :complete
      {done: accumulator}
    end
  end

  class EarlyPartitionReducer
    attr_reader :completed

    def initialize
      @completed = false
    end

    def init
      []
    end

    def call(accumulator, value)
      return Dry::Transformer::Stream.reduced(accumulator) if accumulator.any?

      accumulator + [value]
    end

    def complete(accumulator)
      @completed = true
      accumulator + [:complete]
    end
  end
end
