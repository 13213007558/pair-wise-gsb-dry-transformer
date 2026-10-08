# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Dry
  module Transformer
    # External (disk-backed) stable sort node for streaming pipelines
    #
    # Sorts rows by one or more derived keys while traversing the input
    # exactly once. Rows are buffered up to a configurable memory budget,
    # sorted in memory, and spilled to temporary run files; the runs are
    # then merged with a bounded fan-in (multiple merge rounds when needed),
    # so both memory usage and the number of simultaneously open file
    # descriptors have checkable upper bounds.
    #
    # Stability: every row is tagged with its input sequence number and
    # equal keys are ordered by it, so rows with equal keys keep their
    # original input order across run boundaries. Key functions are called
    # exactly once per row; the computed keys travel with the row through
    # every merge round.
    #
    # Temporary files live in a directory owned by each call and are
    # reclaimed when the consumer stops early or when a comparator raises.
    #
    # @example
    #   sorter = Dry::Transformer::ExternalSort.new(
    #     keys: [-> row { row[:age] }, -> row { row[:name] }],
    #     directions: [:desc, :asc],
    #     nulls: :last,
    #     memory_budget: 1_000,
    #     max_open_files: 8
    #   )
    #
    #   sorter.call(enum_of_rows).each { |row| ... }
    #
    # @api public
    class ExternalSort
      # Raised when a key comparator cannot compare two keys
      #
      # @api public
      IncomparableKeysError = Class.new(Error)

      DEFAULT_MEMORY_BUDGET = 10_000
      DEFAULT_MAX_OPEN_FILES = 16

      DIRECTIONS = %i[asc desc].freeze
      NULL_POSITIONS = %i[first last].freeze

      # Maximum number of rows buffered in memory while forming a run
      #
      # @return [Integer]
      #
      # @api public
      attr_reader :memory_budget

      # Maximum number of simultaneously open run file descriptors
      #
      # @return [Integer]
      #
      # @api public
      attr_reader :max_open_files

      # @param [Array<#call>, #call] keys
      #   One or more key functions, each called once per row
      # @param [Symbol, Array<Symbol>] directions
      #   :asc or :desc, either shared or per key
      # @param [Symbol, Array<Symbol>] nulls
      #   :first or :last, either shared or per key; nil keys are never
      #   passed to comparators
      # @param [Array<#call, nil>, nil] comparators
      #   Optional per-key callables returning -1/0/1 for two non-nil keys;
      #   defaults to <=>
      # @param [Integer] memory_budget
      #   Upper bound of rows held in memory while forming a run
      # @param [Integer] max_open_files
      #   Upper bound of simultaneously open run files (merge fan-in plus
      #   one output file)
      # @param [String, nil] temp_dir
      #   Parent directory for temporary run files
      #
      # @api public
      def initialize(keys:, directions: :asc, nulls: :last, comparators: nil,
                     memory_budget: DEFAULT_MEMORY_BUDGET,
                     max_open_files: DEFAULT_MAX_OPEN_FILES,
                     temp_dir: nil)
        key_fns = Array(keys)
        raise ArgumentError, "at least one key function is required" if key_fns.empty?

        @key_specs = key_fns.each_with_index.map do |fn, idx|
          {
            fn: fn,
            direction: normalize_option(directions, idx, key_fns.size, DIRECTIONS, "direction"),
            nulls: normalize_option(nulls, idx, key_fns.size, NULL_POSITIONS, "nulls"),
            compare: comparators && comparators[idx]
          }
        end

        unless memory_budget.is_a?(Integer) && memory_budget >= 1
          raise ArgumentError, "memory_budget must be an Integer >= 1"
        end

        unless max_open_files.is_a?(Integer) && max_open_files >= 3
          raise ArgumentError,
                "max_open_files must be an Integer >= 3 (at least 2 merge inputs + 1 output)"
        end

        @memory_budget = memory_budget
        @max_open_files = max_open_files
        @temp_dir = temp_dir
      end

      # Number of runs merged in a single pass; one descriptor is reserved
      # for the merge output, so fan_in + 1 <= max_open_files
      #
      # @return [Integer]
      #
      # @api public
      def fan_in
        max_open_files - 1
      end

      # Sort the input, traversing it exactly once
      #
      # @param [Enumerable] enum The input rows
      #
      # @return [Enumerator] Lazily yields rows in sorted order
      #
      # @api public
      def call(enum)
        Enumerator.new do |yielder|
          dir = Dir.mktmpdir("dry-transformer-sort-", @temp_dir)
          begin
            runs = spill_runs(enum, dir)
            runs = reduce_runs(runs, dir)
            stream_merge(runs, yielder)
          ensure
            FileUtils.rm_rf(dir)
          end
        end
      end

      private

      # @api private
      def normalize_option(value, idx, size, allowed, name)
        if value.is_a?(Array) && value.size != size
          raise ArgumentError, "#{name} must have #{size} entries"
        end

        option = value.is_a?(Array) ? value[idx] : value
        unless allowed.include?(option)
          raise ArgumentError, "#{name} must be one of #{allowed.inspect}, got #{option.inspect}"
        end

        option
      end

      # @api private
      def spill_runs(enum, dir)
        runs = []
        buffer = []
        seq = 0

        enum.each do |row|
          keys = @key_specs.map { |spec| spec[:fn].call(row) }
          buffer << [keys, seq, row]
          seq += 1

          if buffer.size >= memory_budget
            runs << write_run(buffer, dir, runs.size)
            buffer = []
          end
        end

        runs << write_run(buffer, dir, runs.size) unless buffer.empty?
        runs
      end

      # @api private
      def write_run(buffer, dir, index)
        sorted = buffer.sort { |left, right| compare_entries(left, right) }
        path = File.join(dir, "run-#{index}.marshal")
        File.open(path, "wb") do |io|
          sorted.each { |entry| Marshal.dump(entry, io) }
        end
        path
      end

      # Merge runs in as many rounds as needed so that no round ever opens
      # more than fan_in inputs plus one output file
      #
      # @api private
      def reduce_runs(runs, dir)
        round = 0
        while runs.size > fan_in
          merged = []
          runs.each_slice(fan_in) do |group|
            if group.size == 1
              merged << group.first
            else
              merged << merge_group_to_file(group, dir, round, merged.size)
            end
          end
          runs = merged
          round += 1
        end
        runs
      end

      # @api private
      def merge_group_to_file(group, dir, round, index)
        path = File.join(dir, "merge-#{round}-#{index}.marshal")
        File.open(path, "wb") do |io|
          each_merged(group) { |entry| Marshal.dump(entry, io) }
        end
        group.each { |run| FileUtils.rm_f(run) }
        path
      end

      # @api private
      def stream_merge(runs, yielder)
        each_merged(runs) { |entry| yielder << entry[2] }
      end

      # K-way merge over run files; holds at most one entry per open run in
      # memory and never opens more than runs.size (<= fan_in) files
      #
      # @api private
      def each_merged(runs)
        readers = runs.map { |path| RunReader.new(path) }
        begin
          heads = readers.map(&:advance)
          loop do
            best = nil
            heads.each_with_index do |entry, idx|
              next if entry.nil?

              best = idx if best.nil? || compare_entries(entry, heads[best]).negative?
            end
            break if best.nil?

            yield heads[best]
            heads[best] = readers[best].advance
          end
        ensure
          readers.each(&:close)
        end
      end

      # Total order over [keys, seq, row] entries: key by key, then input
      # sequence number for stability
      #
      # @api private
      def compare_entries(left, right)
        left_keys, left_seq, = left
        right_keys, right_seq, = right

        @key_specs.each_with_index do |spec, idx|
          cmp = compare_keys(left_keys[idx], right_keys[idx], spec)
          return cmp unless cmp.zero?
        end

        left_seq <=> right_seq
      end

      # @api private
      def compare_keys(left, right, spec)
        if left.nil?
          return 0 if right.nil?

          return spec[:nulls] == :first ? -1 : 1
        elsif right.nil?
          return spec[:nulls] == :first ? 1 : -1
        end

        cmp = spec[:compare] ? spec[:compare].call(left, right) : (left <=> right)
        if cmp.nil?
          raise IncomparableKeysError, "cannot compare keys #{left.inspect} and #{right.inspect}"
        end

        cmp = cmp <=> 0
        spec[:direction] == :desc ? -cmp : cmp
      end

      # Sequentially reads marshalled entries from a single run file
      #
      # @api private
      class RunReader
        def initialize(path)
          @io = File.open(path, "rb")
        end

        # @return [Array, nil] the next entry, or nil at end of run
        def advance
          Marshal.load(@io)
        rescue EOFError
          nil
        end

        def close
          @io.close unless @io.closed?
        end
      end
    end
  end
end
