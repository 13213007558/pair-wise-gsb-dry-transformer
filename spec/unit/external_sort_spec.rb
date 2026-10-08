# frozen_string_literal: true

require "tmpdir"

RSpec.describe Dry::Transformer::ExternalSort do
  # Independent in-memory stable sort used as the reference oracle
  def reference_sort(rows, keys:, directions: :asc, nulls: :last, comparators: nil)
    key_fns = Array(keys)
    dirs = directions.is_a?(Array) ? directions : [directions] * key_fns.size
    null_positions = nulls.is_a?(Array) ? nulls : [nulls] * key_fns.size

    rows.each_with_index.map { |row, idx| [key_fns.map { |fn| fn.call(row) }, idx, row] }
        .sort do |(left_keys, left_idx, _), (right_keys, right_idx, _)|
          cmp = 0
          key_fns.size.times do |k|
            left = left_keys[k]
            right = right_keys[k]
            part =
              if left.nil? && right.nil?
                0
              elsif left.nil?
                null_positions[k] == :first ? -1 : 1
              elsif right.nil?
                null_positions[k] == :first ? 1 : -1
              else
                value = comparators && comparators[k] ? comparators[k].call(left, right) : left <=> right
                dirs[k] == :desc ? -value : value
              end
            if part != 0
              cmp = part
              break
            end
          end
          cmp.zero? ? left_idx <=> right_idx : cmp
        end
        .map(&:last)
  end

  def build_rows(count, seed: 42)
    rng = Random.new(seed)
    Array.new(count) do |idx|
      {
        id: idx,
        a: rng.rand(10).then { |v| v.zero? ? nil : v },
        b: rng.rand(5).then { |v| v.zero? ? nil : "k#{v}" }
      }
    end
  end

  # Enumerable that may be traversed only once
  class OnceOnly
    include Enumerable

    attr_reader :traversals

    def initialize(rows)
      @rows = rows
      @traversals = 0
    end

    def each(&block)
      @traversals += 1
      raise "input traversed more than once" if @traversals > 1

      @rows.each(&block)
    end
  end

  describe "#call" do
    it "matches in-memory stable sort when forced through many merge rounds" do
      rows = build_rows(200)
      sorter = described_class.new(
        keys: [-> row { row[:a] }, -> row { row[:b] }],
        memory_budget: 3,
        max_open_files: 4
      )

      expect(sorter.call(rows).to_a).to eql(
        reference_sort(rows, keys: [-> row { row[:a] }, -> row { row[:b] }])
      )
    end

    it "matches the reference with the smallest possible fan-in" do
      rows = build_rows(100, seed: 7)
      sorter = described_class.new(
        keys: -> row { row[:a] },
        memory_budget: 2,
        max_open_files: 3
      )

      expect(sorter.call(rows).to_a).to eql(reference_sort(rows, keys: -> row { row[:a] }))
    end

    it "supports per-key directions and explicit null positions" do
      rows = build_rows(150, seed: 11)
      keys = [-> row { row[:a] }, -> row { row[:b] }]
      sorter = described_class.new(
        keys: keys,
        directions: [:desc, :asc],
        nulls: [:first, :last],
        memory_budget: 4,
        max_open_files: 4
      )

      expect(sorter.call(rows).to_a).to eql(
        reference_sort(rows, keys: keys, directions: [:desc, :asc], nulls: [:first, :last])
      )
    end

    it "keeps nils last even under descending order" do
      rows = [{ v: 2 }, { v: nil }, { v: 1 }, { v: nil }, { v: 3 }]
      sorter = described_class.new(keys: -> row { row[:v] }, directions: :desc, nulls: :last)

      expect(sorter.call(rows).to_a).to eql([{ v: 3 }, { v: 2 }, { v: 1 }, { v: nil }, { v: nil }])
    end

    it "honours caller-provided key comparators" do
      rows = [{ name: "ccc" }, { name: "a" }, { name: "bb" }, { name: "dddd" }, { name: "a" }]
      by_length = ->(left, right) { left.length <=> right.length }
      sorter = described_class.new(
        keys: -> row { row[:name] },
        comparators: [by_length],
        memory_budget: 2,
        max_open_files: 3
      )

      expect(sorter.call(rows).to_a).to eql(
        reference_sort(rows, keys: -> row { row[:name] }, comparators: [by_length])
      )
    end

    it "preserves input order for equal keys across run boundaries" do
      rows = Array.new(50) { |idx| { id: idx, group: idx % 2 } }
      sorter = described_class.new(keys: -> row { row[:group] }, memory_budget: 3, max_open_files: 3)

      result = sorter.call(rows).to_a
      expect(result.map { |row| row[:id] }).to eql(
        rows.select { |row| row[:group].zero? }.map { |row| row[:id] } +
          rows.select { |row| row[:group] == 1 }.map { |row| row[:id] }
      )
    end

    it "calls each key function exactly once per row" do
      rows = build_rows(40, seed: 3)
      calls = Hash.new(0)
      counted = -> row { calls[row[:id]] += 1; row[:a] }
      sorter = described_class.new(keys: counted, memory_budget: 3, max_open_files: 3)

      sorter.call(rows).to_a

      expect(calls.size).to eql(rows.size)
      expect(calls.values).to all(eql(1))
    end

    it "traverses the input exactly once" do
      rows = build_rows(30, seed: 5)
      input = OnceOnly.new(rows)
      sorter = described_class.new(keys: -> row { row[:a] }, memory_budget: 2, max_open_files: 3)

      expect(sorter.call(input).to_a).to eql(reference_sort(rows, keys: -> row { row[:a] }))
      expect(input.traversals).to eql(1)
    end

    it "returns an empty enumerator for empty input" do
      sorter = described_class.new(keys: -> row { row[:a] })
      expect(sorter.call([]).to_a).to eql([])
    end
  end

  describe "resource bounds" do
    it "exposes checkable memory and file descriptor budgets" do
      sorter = described_class.new(keys: -> row { row }, memory_budget: 10, max_open_files: 6)

      expect(sorter.memory_budget).to eql(10)
      expect(sorter.max_open_files).to eql(6)
      expect(sorter.fan_in).to eql(5)
    end

    it "rejects a memory budget below one row" do
      expect { described_class.new(keys: -> row { row }, memory_budget: 0) }
        .to raise_error(ArgumentError, /memory_budget/)
    end

    it "rejects a descriptor budget too small to merge" do
      expect { described_class.new(keys: -> row { row }, max_open_files: 2) }
        .to raise_error(ArgumentError, /max_open_files/)
    end

    it "rejects unknown direction and null options" do
      expect { described_class.new(keys: -> row { row }, directions: :sideways) }
        .to raise_error(ArgumentError, /direction/)
      expect { described_class.new(keys: -> row { row }, nulls: :middle) }
        .to raise_error(ArgumentError, /nulls/)
    end
  end

  describe "temporary file reclamation" do
    it "removes owned temp files when the consumer stops early" do
      Dir.mktmpdir do |parent|
        rows = build_rows(100, seed: 13)
        sorter = described_class.new(
          keys: -> row { row[:a] },
          memory_budget: 2,
          max_open_files: 3,
          temp_dir: parent
        )

        sorter.call(rows).each { |row| break }

        expect(Dir.children(parent)).to be_empty
      end
    end

    it "removes owned temp files when a comparator fails" do
      Dir.mktmpdir do |parent|
        rows = build_rows(50, seed: 17)
        failing = ->(_left, _right) { raise "comparator exploded" }
        sorter = described_class.new(
          keys: -> row { row[:a] },
          comparators: [failing],
          memory_budget: 4,
          max_open_files: 3,
          temp_dir: parent
        )

        expect { sorter.call(rows).to_a }.to raise_error("comparator exploded")
        expect(Dir.children(parent)).to be_empty
      end
    end

    it "raises IncomparableKeysError when a comparator returns nil and cleans up" do
      Dir.mktmpdir do |parent|
        rows = [{ v: 1 }, { v: 2 }, { v: 3 }]
        nil_comparator = ->(_left, _right) { nil }
        sorter = described_class.new(
          keys: -> row { row[:v] },
          comparators: [nil_comparator],
          memory_budget: 2,
          max_open_files: 3,
          temp_dir: parent
        )

        expect { sorter.call(rows).to_a }
          .to raise_error(Dry::Transformer::ExternalSort::IncomparableKeysError)
        expect(Dir.children(parent)).to be_empty
      end
    end

    it "leaves unrelated sibling files untouched" do
      Dir.mktmpdir do |parent|
        keep = File.join(parent, "keep.txt")
        File.write(keep, "precious")

        rows = build_rows(20, seed: 19)
        sorter = described_class.new(
          keys: -> row { row[:a] },
          memory_budget: 2,
          max_open_files: 3,
          temp_dir: parent
        )
        sorter.call(rows).to_a

        expect(Dir.children(parent)).to eql(["keep.txt"])
        expect(File.read(keep)).to eql("precious")
      end
    end
  end
end
