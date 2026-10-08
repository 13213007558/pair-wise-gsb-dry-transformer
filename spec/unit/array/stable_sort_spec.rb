# frozen_string_literal: true

require "tmpdir"

RSpec.describe Dry::Transformer::ArrayTransformations::StableSort do
  describe "#each" do
    it "sorts multiple derived keys with directions, null positions, and comparators" do
      input = [
        {a: nil, b: nil, id: 0},
        {a: nil, b: nil, id: 1},
        {a: nil, b: '33', id: 2},
        {a: 2, b: nil, id: 3},
        {a: 2, b: '111', id: 4},
        {a: 2, b: '22', id: 5},
        {a: 1, b: '22', id: 6},
        {a: 1, b: nil, id: 7}
      ]

      comparator = ->(left, right) { left <=> right }
      length_comparator = ->(left, right) { left.length <=> right.length }
      sort = described_class.new(
        input,
        keys: [->(row) { row[:a] }, ->(row) { row[:b] }],
        orders: [:asc, :desc],
        null_positions: [:last, :first],
        comparators: [comparator, length_comparator],
        budget: 1,
        fan_in: 2
      )

      expect(sort.to_a.map { |row| row[:id] }).to eql([7, 6, 3, 4, 5, 0, 1, 2])
    end

    it "does not call comparators with nil and calls every key once per row" do
      comparator_calls = []
      first_key_calls = 0
      second_key_calls = 0
      comparator = lambda do |left, right|
        comparator_calls << [left, right]
        left <=> right
      end
      input = [
        {a: nil, b: 1},
        {a: 1, b: nil},
        {a: nil, b: 2},
        {a: 1, b: 2}
      ]
      sort = described_class.new(
        input,
        keys: [
          ->(row) { first_key_calls += 1; row[:a] },
          ->(row) { second_key_calls += 1; row[:b] }
        ],
        comparators: [comparator, comparator],
        budget: 1,
        fan_in: 2
      )

      expect(sort.map { |row| input.index(row) }).to eql([3, 1, 0, 2])
      expect(comparator_calls).to all(satisfy { |left, right| !left.nil? && !right.nil? })
      expect(first_key_calls).to be(4)
      expect(second_key_calls).to be(4)
    end

    it "uses multiple merge rounds with a small budget and matches memory sort row by row" do
      input = 50.times.map { |index| {key: index % 7, sequence: index} }
      expected = input.sort_by { |row| [row[:key], row[:sequence]] }
      key_calls = 0
      tempdir = Dir.mktmpdir("dry-transformer-stable-sort-spec")
      sort = described_class.new(
        input,
        key: ->(row) { key_calls += 1; row[:key] },
        budget: 1,
        fan_in: 2,
        tempdir: tempdir
      )
      enumerator = sort.each

      expected.each_with_index do |expected_row, index|
        expect(enumerator.next).to eql(expected_row), "row #{index} differs"
      end

      expect { enumerator.next }.to raise_error(StopIteration)
      expect(key_calls).to be(50)
      expect(sort.runs_written).to be > 50
      expect(sort.merge_rounds).to be >= 2
      expect(Dir.children(tempdir)).to be_empty
    ensure
      FileUtils.remove_entry(tempdir, true)
    end

    it "preserves original order for equal keys across runs" do
      input = 20.times.map { |index| {key: "same", sequence: index} }
      sort = described_class.new(
        input,
        key: ->(row) { row[:key] },
        budget: 1,
        fan_in: 2
      )

      expect(sort.map { |row| row[:sequence] }).to eql((0..19).to_a)
    end

    it "reclaims runs when the consumer stops early" do
      tempdir = Dir.mktmpdir("dry-transformer-stable-sort-spec")
      input = 12.times.map { |index| {key: index} }
      sort = described_class.new(
        input,
        key: ->(row) { row[:key] },
        budget: 1,
        fan_in: 2,
        tempdir: tempdir
      )
      enumerator = sort.each

      expect(enumerator.next).to eql(key: 0)
      enumerator.close

      expect(Dir.children(tempdir)).to be_empty
    ensure
      FileUtils.remove_entry(tempdir, true)
    end

    it "reclaims runs when a block consumer breaks" do
      tempdir = Dir.mktmpdir("dry-transformer-stable-sort-spec")
      sort = described_class.new(
        12.times.to_a,
        budget: 1,
        fan_in: 2,
        tempdir: tempdir
      )

      sort.each do |row|
        expect(row).to be(0)
        break
      end

      expect(Dir.children(tempdir)).to be_empty
    ensure
      FileUtils.remove_entry(tempdir, true)
    end

    it "raises StopIteration when next is called after close" do
      enumerator = described_class.new([1, 2], budget: 1).each

      enumerator.close

      expect { enumerator.next }.to raise_error(StopIteration, /closed/)
    end

    it "reclaims runs when a comparator fails during a merge" do
      tempdir = Dir.mktmpdir("dry-transformer-stable-sort-spec")
      comparator = lambda do |left, right|
        raise "cross-run comparison" unless left.even? == right.even?

        left <=> right
      end
      sort = described_class.new(
        [2, 1],
        comparator: comparator,
        budget: 1,
        fan_in: 2,
        tempdir: tempdir
      )

      expect { sort.to_a }.to raise_error(RuntimeError, "cross-run comparison")
      expect(Dir.children(tempdir)).to be_empty
    ensure
      FileUtils.remove_entry(tempdir, true)
    end

    it "reclaims runs when a comparator fails while writing a spill" do
      tempdir = Dir.mktmpdir("dry-transformer-stable-sort-spec")
      sort = described_class.new(
        [2, 1],
        comparator: ->(_left, _right) { raise "spill comparison" },
        budget: 1,
        fan_in: 2,
        tempdir: tempdir
      )

      expect { sort.to_a }.to raise_error(RuntimeError, "spill comparison")
      expect(Dir.children(tempdir)).to be_empty
    ensure
      FileUtils.remove_entry(tempdir, true)
    end

    it "does not traverse the input before iteration" do
      traversals = 0
      input = Object.new
      input.define_singleton_method(:each) do |&block|
        traversals += 1
        [3, 1, 2].each(&block)
      end

      sort = described_class.new(input, budget: 2)

      expect(traversals).to be(0)
      expect(sort.to_a).to eql([1, 2, 3])
      expect(traversals).to be(1)
      expect { sort.to_a }.to raise_error(IOError, /only be traversed once/)
      expect(traversals).to be(1)
    end
  end

  describe "#memory_budget and #file_descriptor_budget" do
    it "exposes the bounded number of records and open run files" do
      sort = described_class.new([], budget: 1, fan_in: 2)

      expect(sort.memory_budget).to be(2)
      expect(sort.file_descriptor_budget).to be(3)
    end

    it "rejects invalid budgets" do
      expect { described_class.new([], budget: 0) }
        .to raise_error(ArgumentError, /budget must be greater than 0/)
      expect { described_class.new([], fan_in: 1) }
        .to raise_error(ArgumentError, /fan_in must be greater than 1/)
      expect { described_class.new(:invalid) }
        .to raise_error(ArgumentError, /input must respond to #each/)
    end
  end

  describe Dry::Transformer::ArrayTransformations do
    it "exposes stable sorting as an array transformation" do
      transform = described_class[:stable_sort, key: ->(row) { row[:key] }, budget: 1]

      expect(transform.call([{key: 2}, {key: 1}, {key: 2}]).to_a)
        .to eql([{key: 1}, {key: 2}, {key: 2}])
    end

    it "supports the external_sort alias" do
      transform = described_class[:external_sort, key: ->(row) { row[:key] }, budget: 1]

      expect(transform.call([{key: 2}, {key: 1}]).to_a)
        .to eql([{key: 1}, {key: 2}])
    end
  end
end
