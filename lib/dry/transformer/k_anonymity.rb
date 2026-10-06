# frozen_string_literal: true

module Dry
  module Transformer
    # Offline k-anonymity via full-domain generalization with bounded suppression.
    #
    # Given a table (an array of row hashes), a set of quasi-identifier fields,
    # per-field generalization hierarchies and a maximum suppression ratio, the
    # search finds a globally consistent scheme — one hierarchy level per
    # quasi-identifier, applied uniformly to every row — that satisfies
    # k-anonymity while keeping information loss low.
    #
    # Only quasi-identifier values participate in grouping; any other
    # (sensitive) attributes are never read and never influence the scheme.
    #
    # Categorical hierarchies are parent maps, e.g.
    #   {"beijing" => "china", "shanghai" => "china", "china" => "*"}
    # Level 0 keeps the raw value; each further level walks one step up the
    # map. Values absent from the map (including nil) stay as they are.
    #
    # Numeric hierarchies are arrays of interval levels, each level a sorted
    # list of bin edges, e.g. [[0, 18, 65, 120], [0, 65, 120]]. Level 0 keeps
    # the raw value; level i bins values into the intervals of edges[i - 1].
    #
    # @example
    #   result = Dry::Transformer::KAnonymity.call(
    #     rows,
    #     quasi_identifiers: %i[age city],
    #     k: 2,
    #     max_suppression: 0.25,
    #     categorical_hierarchies: {city: {"paris" => "france", "lyon" => "france"}},
    #     numeric_hierarchies: {age: [[0, 40, 120]]}
    #   )
    #   result.scheme           # => {age: 1, city: 0}
    #   result.assignments      # => per-row generalized quasi-identifiers or :suppressed
    #   result.suppressed       # => indices of suppressed rows
    #   result.loss             # => normalized information loss in 0..1
    #   result.proven_optimal?  # => false when the evaluation budget ran out
    #
    # @api public
    class KAnonymity
      # Marker used in Result#assignments for suppressed rows
      SUPPRESSED = :suppressed

      # Outcome of a k-anonymity search
      class Result
        # @return [Hash{Symbol => Integer}] chosen hierarchy level per quasi-identifier
        attr_reader :scheme

        # @return [Array<Hash, Symbol>] per-row destination: a hash of
        #   generalized quasi-identifiers for kept rows, SUPPRESSED otherwise
        attr_reader :assignments

        # @return [Array<Integer>] indices of suppressed rows
        attr_reader :suppressed

        # @return [Float] normalized information loss in 0..1
        attr_reader :loss

        # @return [Integer] number of lattice nodes evaluated during the search
        attr_reader :evaluations

        def initialize(scheme:, assignments:, suppressed:, loss:, evaluations:, feasible:, proven_optimal:)
          @scheme = scheme
          @assignments = assignments
          @suppressed = suppressed
          @loss = loss
          @evaluations = evaluations
          @feasible = feasible
          @proven_optimal = proven_optimal
        end

        # @return [Boolean] whether a k-anonymous scheme was found
        def feasible?
          @feasible
        end

        # @return [Boolean] whether the returned scheme is proven to minimize
        #   loss (false when the evaluation budget ran out first)
        def proven_optimal?
          @proven_optimal
        end
      end

      # Generalizes categorical values by walking a parent map
      #
      # @api private
      class CategoricalGeneralizer
        attr_reader :max_level

        def initialize(parents)
          @parents = parents
          @max_level = parents.keys.map { |value| chain_depth(value) }.max || 0
        end

        def call(value, level)
          level.times.reduce(value) { |current, *| @parents.fetch(current, current) }
        end

        private

        def chain_depth(value, seen = {})
          return 0 if seen[value] || !@parents.key?(value)

          seen[value] = true
          1 + chain_depth(@parents[value], seen)
        end
      end

      # Generalizes numeric values into interval labels
      #
      # @api private
      class NumericGeneralizer
        attr_reader :max_level

        def initialize(levels)
          @levels = levels.map(&:sort)
          @max_level = @levels.size
        end

        def call(value, level)
          return value if level.zero? || value.nil?

          edges = @levels[level - 1]
          index = edges.rindex { |edge| value >= edge }
          if index.nil?
            "<#{edges.first}"
          elsif index == edges.size - 1
            ">=#{edges.last}"
          else
            "#{edges[index]}-#{edges[index + 1]}"
          end
        end
      end

      # Min-heap of [priority, sequence, payload] entries
      #
      # @api private
      class Heap
        def initialize
          @items = []
          @sequence = 0
        end

        def empty?
          @items.empty?
        end

        def push(priority, payload)
          @items << [priority, @sequence += 1, payload]
          sift_up(@items.size - 1)
        end

        def pop
          top = @items.first
          last = @items.pop
          unless @items.empty?
            @items[0] = last
            sift_down(0)
          end
          top&.[](2)
        end

        private

        def sift_up(index)
          while index.positive?
            parent = (index - 1) / 2
            break if (@items[parent] <=> @items[index]) <= 0

            @items[parent], @items[index] = @items[index], @items[parent]
            index = parent
          end
        end

        def sift_down(index)
          loop do
            smallest = index
            [2 * index + 1, 2 * index + 2].each do |child|
              smallest = child if child < @items.size && (@items[child] <=> @items[smallest]).negative?
            end
            break if smallest == index

            @items[smallest], @items[index] = @items[index], @items[smallest]
            index = smallest
          end
        end
      end

      def self.call(rows, **options)
        new(**options).call(rows)
      end

      def initialize(quasi_identifiers:, k:, max_suppression: 0.0,
                     categorical_hierarchies: {}, numeric_hierarchies: {},
                     max_evaluations: 10_000)
        @fields = quasi_identifiers
        @k = k
        @max_suppression = max_suppression
        @max_evaluations = max_evaluations
        @generalizers = quasi_identifiers.to_h do |field|
          generalizer =
            if numeric_hierarchies.key?(field)
              NumericGeneralizer.new(numeric_hierarchies[field])
            else
              CategoricalGeneralizer.new(categorical_hierarchies.fetch(field, {}))
            end
          [field, generalizer]
        end
      end

      def call(rows)
        @rows = rows
        @evaluations = 0
        return empty_result if rows.empty?

        @max_suppressed = (@max_suppression * rows.size).floor
        search
      end

      private

      # Uniform-cost search over the level lattice. Loss never decreases when
      # moving to a more generalized node, so the first feasible node popped
      # is optimal — unless the evaluation budget cut the search short.
      def search
        heap = Heap.new
        visited = {}
        start = Array.new(@fields.size, 0)
        visited[start] = true
        push_node(heap, start)
        exhausted = false

        until heap.empty?
          node, node_eval = heap.pop
          return build_result(node, node_eval, proven_optimal: !exhausted) if node_eval[:feasible]
          next if exhausted

          children(node).each do |child|
            next if visited[child]

            visited[child] = true
            push_node(heap, child)
            if @evaluations >= @max_evaluations
              exhausted = true
              break
            end
          end
        end

        infeasible_result
      end

      def push_node(heap, node)
        node_eval = evaluate(node)
        heap.push([node_eval[:loss], node_eval[:suppressed].size, *node], [node, node_eval])
      end

      def children(node)
        @fields.each_index.filter_map do |index|
          next if node[index] >= @generalizers[@fields[index]].max_level

          child = node.dup
          child[index] += 1
          child
        end
      end

      def evaluate(scheme)
        @evaluations += 1
        groups = Hash.new { |hash, key| hash[key] = [] }
        keys = @rows.map.with_index do |row, row_index|
          key = @fields.each_with_index.map do |field, field_index|
            @generalizers[field].call(row[field], scheme[field_index])
          end
          groups[key] << row_index
          key
        end
        suppressed = groups.values.select { |indices| indices.size < @k }.flatten.sort
        {
          feasible: suppressed.size <= @max_suppressed,
          suppressed: suppressed,
          loss: loss(scheme, suppressed.size),
          keys: keys
        }
      end

      # Kept rows all share the same per-row loss (global levels); a
      # suppressed row costs as much as a fully generalized one.
      def loss(scheme, suppressed_count)
        denominator = @fields.count { |field| @generalizers[field].max_level.positive? }
        return 0.0 if denominator.zero?

        per_row = @fields.each_with_index.sum do |field, index|
          max_level = @generalizers[field].max_level
          max_level.positive? ? scheme[index].to_f / max_level : 0.0
        end
        total = per_row * (@rows.size - suppressed_count) + suppressed_count * denominator
        total / (@rows.size * denominator)
      end

      def build_result(scheme, node_eval, proven_optimal:)
        suppressed = node_eval[:suppressed]
        membership = suppressed.to_h { |index| [index, true] }
        assignments = node_eval[:keys].map.with_index do |key, row_index|
          if membership[row_index]
            SUPPRESSED
          else
            @fields.each_with_index.to_h { |field, field_index| [field, key[field_index]] }
          end
        end
        Result.new(
          scheme: @fields.each_with_index.to_h { |field, index| [field, scheme[index]] },
          assignments: assignments,
          suppressed: suppressed,
          loss: node_eval[:loss],
          evaluations: @evaluations,
          feasible: true,
          proven_optimal: proven_optimal
        )
      end

      def infeasible_result
        Result.new(
          scheme: {},
          assignments: [],
          suppressed: [],
          loss: 1.0,
          evaluations: @evaluations,
          feasible: false,
          proven_optimal: false
        )
      end

      def empty_result
        Result.new(
          scheme: @fields.to_h { |field| [field, 0] },
          assignments: [],
          suppressed: [],
          loss: 0.0,
          evaluations: @evaluations,
          feasible: true,
          proven_optimal: true
        )
      end
    end
  end
end
