# frozen_string_literal: true

RSpec.describe Dry::Transformer::Flow do
  let(:transformations) { Dry::Transformer::ArrayTransformations }

  let(:pipeline) do
    transformations[:map, -> value { value * 2 }] >>
      transformations[:filter, -> value { value < 10 }] >>
      transformations[:flat_map, -> value { [value, value.next] }] >>
      transformations[:take, 3]
  end

  it "matches eager execution with a fused pipeline" do
    eager_source = TrackingEnumerable.new([1, 2, 3, 4])
    stream_source = TrackingEnumerable.new([1, 2, 3, 4])

    expect(pipeline.stream(stream_source)).to eql(pipeline.call(eager_source))
    expect(stream_source.pulls).to be(2)
    expect(eager_source.pulls).to be(4)
  end

  it "keeps map compatible with eager scalar coercion" do
    map = transformations[:map, :to_s.to_proc]

    expect(map.stream(1)).to eql(map.call(1))
  end

  it "does not pull another item after take reaches its limit" do
    source = TrackingEnumerable.new([1, 2, 3, 4])
    limited = transformations[:map, -> value { value * 2 }] >> transformations[:take, 2]

    expect(limited.stream(source)).to eql([2, 4])
    expect(source.pulls).to be(2)
  end

  it "stops inside a flat-mapped array without pulling another source item" do
    source = TrackingEnumerable.new([1, 2, 3])
    limited =
      transformations[:flat_map, -> value { [value, value * 10] }] >>
      transformations[:take, 3]

    expect(limited.stream(source)).to eql([1, 10, 2])
    expect(source.pulls).to be(2)
  end

  it "does not read an item for a zero-sized take" do
    source = TrackingEnumerable.new([1, 2, 3])

    expect(transformations[:take, 0].stream(source)).to eql([])
    expect(source.pulls).to be(0)
  end

  it "flushes the final partition group when input ends normally" do
    chunked =
      transformations[:filter, :even?.to_proc] >>
      transformations[:partition, 2]

    expect(chunked.stream((1..5).to_a)).to eql([[2, 4]])
  end

  it "keeps a final partition group buffered when reduction terminates early" do
    reducer_class = Class.new do
      attr_reader :completed

      def initialize
        @completed = false
      end

      def init
        []
      end

      def call(output, value)
        output << value
        return Dry::Transformer::Flow.reduced(output) if output.size == 1

        output
      end

      def complete(output)
        @completed = true
        output
      end
    end
    reducer = reducer_class.new
    chunked =
      transformations[:partition, 2] >>
      transformations[:map, :inspect.to_proc]

    expect(chunked.stream((1..4).to_a, reducer)).to eql(["[1, 2]"])
    expect(reducer.completed).to be(false)
  end

  it "does not complete the reducer when an exception is raised" do
    reducer_class = Class.new do
      attr_reader :completed

      def initialize
        @completed = false
      end

      def init
        []
      end

      def call(output, value)
        output << value
      end

      def complete(output)
        @completed = true
        output
      end
    end
    reducer = reducer_class.new
    failing =
      transformations[:map, -> value { raise "boom" if value == 2; value }] >>
      transformations[:partition, 2]

    expect { failing.stream([1, 2, 3], reducer) }.to raise_error(RuntimeError, "boom")
    expect(reducer.completed).to be(false)
  end

  it "uses a caller-provided block reducer" do
    summed =
      transformations[:filter, :odd?.to_proc] >>
      transformations[:map, -> value { value * 2 }]

    expect(summed.stream([1, 2, 3, 4], 0) { |sum, value| sum + value }).to be(8)
  end

  it "honors a caller-provided break signal without completion" do
    reducer_class = Class.new do
      attr_reader :completed

      def initialize
        @completed = false
      end

      def init
        []
      end

      def call(output, value)
        throw(:break, output) if value == 3

        output << value
      end

      def complete(output)
        @completed = true
        output
      end
    end
    reducer = reducer_class.new

    expect(transformations[:take, 4].stream([1, 2, 3, 4], reducer)).to eql([1, 2])
    expect(reducer.completed).to be(false)
  end

  it "uses a caller-provided callable reducer" do
    reducer = ->(sum, value) { sum + value }
    summed = transformations[:take, 2]

    expect(summed.transduce([1, 2, 3], reducer, 10)).to be(13)
  end

  it "uses a caller-provided symbol reducer" do
    collected = transformations[:map, -> value { value.to_s }]

    expect(collected.transduce([1, 2], :<<)).to eql(%w[1 2])
  end

  it "builds a stream directly from a composite pipeline" do
    collected = transformations[:take, 2]

    expect(described_class.stream(collected, [1, 2, 3])).to eql([1, 2])
  end

  it "rejects a negative take count when building the streaming stage" do
    expect { transformations[:take, -1].stream([1]) }.to raise_error(ArgumentError, /non-negative integer/)
  end

  it "rejects transformations that cannot be fused" do
    unsupported =
      transformations[:map, :to_s.to_proc] >>
      transformations[:wrap, :user, [:name]]

    expect { unsupported.stream([]) }
      .to raise_error(described_class::UnsupportedTransformationError, /wrap/)
  end

  it "streams through a pipe" do
    registry = Module.new do
      extend Dry::Transformer::Registry

      import Dry::Transformer::ArrayTransformations
    end

    transformer_class = Class.new(Dry::Transformer[registry]) do
      define! do
        filter(:odd?.to_proc)
        take(2)
      end
    end
    source = TrackingEnumerable.new([1, 2, 3, 4])

    expect(transformer_class.new.stream(source)).to eql([1, 3])
    expect(source.pulls).to be(3)
  end

  class TrackingEnumerable
    include Enumerable

    attr_reader :pulls

    def initialize(values)
      @values = values
      @pulls = 0
      @consumed = false
    end

    def each
      raise "enumerable can only be consumed once" if @consumed

      @consumed = true
      @values.each do |value|
        @pulls += 1
        yield value
      end
    end
  end
end
