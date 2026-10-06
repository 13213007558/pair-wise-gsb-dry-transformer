# frozen_string_literal: true

require "set"

module Dry
  module Transformer
    module KAnonymity
      # Searches the full-domain generalization lattice for the least lossy
      # scheme satisfying `k` and the suppression budget.
      #
      # Every quasi-identifier column is generalized at one global level.
      # Column level combinations are enumerated from the least generalized
      # scheme; an admissible lower bound prunes branches that cannot beat
      # the best feasible scheme already found.
      #
      # @api private
      class Solver
        # Relative tolerance used when comparing information loss
        #
        # @api private
        EPSILON = 1e-12

        # @api private
        def initialize(rows, hierarchies, k:, max_suppression:, budget:)
          @rows = rows
          @hierarchies = hierarchies
          @k = k
          @max_suppression = max_suppression
          @budget = budget

          @column_count = hierarchies.size
          @row_count = rows.size
        end

        # @api private
        def call
          prepare
          search
          build_result
        end

        private

        # @api private
        def prepare
          # generalized[column][level][row] and losses[column][level][row]
          @generalized = @hierarchies.map do |hierarchy|
            values = @rows.map { |row| row[hierarchy.key] }
            (0..hierarchy.levels).map do |level|
              values.map do |value|
                [hierarchy.generalize(value, level), hierarchy.loss(value, level)]
              end
            end
          end

          @cell_losses = @generalized.map do |by_level|
            by_level.map { |pairs| pairs.map { |pair| pair.last } }
          end
          @generalized = @generalized.map do |by_level|
            by_level.map { |pairs| pairs.map { |pair| pair.first } }
          end

          @total_schemes = @hierarchies.reduce(1) do |total, hierarchy|
            total * (hierarchy.levels + 1)
          end

          @evaluations = 0
          @best_levels = nil
          @best_loss = nil
          @fully_explored = true
        end

        # Depth-first enumeration of the level lattice.
        #
        # @param [Integer] column Next column whose level is being chosen
        # @param [Array<Integer>] levels Fixed levels for earlier columns
        # @param [Float] lower_bound Generalization loss accumulated so far
        #
        # @api private
        def search(column = 0, levels = [], lower_bound = 0.0)
          return if budget_exhausted?

          if column == @column_count
            evaluate(levels)
            return
          end

          hierarchy = @hierarchies[column]
          (0..hierarchy.levels).each do |level|
            break if budget_exhausted?

            bound = lower_bound + column_lower_bound(column, level)
            next if @best_loss && bound + EPSILON >= @best_loss

            search(column + 1, levels + [level], bound)
          end
        end

        # Generalization loss accumulated by fixing one column to a level,
        # on the same scale as `#evaluate` but ignoring suppression.
        #
        # @api private
        def column_lower_bound(column, level)
          cells = @cell_losses[column][level]
          return 0.0 if @column_count.zero? || @row_count.zero?

          cells.sum.to_f / (@column_count * @row_count)
        end

        # @api private
        def evaluate(levels)
          @evaluations += 1

          groups = group_rows(levels)
          suppressed_set = suppressed_indices(groups)
          suppressed = suppressed_set.size

          rate = @row_count.zero? ? 0.0 : suppressed.to_f / @row_count
          return if rate > @max_suppression + EPSILON

          loss = total_loss(levels, suppressed_set, suppressed)
          return if @best_loss && loss + EPSILON >= @best_loss

          @best_loss = loss
          @best_levels = levels
        end

        # @api private
        def group_rows(levels)
          groups = ::Hash.new { |hash, key| hash[key] = [] }
          @row_count.times do |row_index|
            signature = @column_count.times.map do |column|
              @generalized[column][levels[column]][row_index]
            end
            groups[signature] << row_index
          end
          groups
        end

        # @api private
        def suppressed_indices(groups)
          groups.each_value.with_object(::Set.new) do |indices, suppressed|
            indices.each { |index| suppressed << index } if indices.size < @k
          end
        end

        # @api private
        def total_loss(levels, suppressed_set, suppressed)
          return 0.0 if @row_count.zero?

          numerator = suppressed.to_f
          return numerator / @row_count if @column_count.zero?

          @row_count.times do |row_index|
            next if suppressed_set.include?(row_index)

            cell_sum = @column_count.times.sum do |column|
              @cell_losses[column][levels[column]][row_index]
            end
            numerator += cell_sum.to_f / @column_count
          end

          numerator / @row_count
        end

        # @api private
        def budget_exhausted?
          if @budget && @evaluations >= @budget
            @fully_explored = false
            true
          else
            false
          end
        end

        # @api private
        def build_result
          unless @best_levels
            return Result.new(
              levels: nil,
              rows: [],
              destinations: all_suppressed_destinations,
              suppressed_rows: @rows.dup,
              suppressed_count: @row_count,
              suppression_rate: @row_count.zero? ? 0.0 : 1.0,
              loss: 1.0,
              feasible: false,
              proven_optimal: @fully_explored,
              evaluations: @evaluations,
              total_schemes: @total_schemes
            )
          end

          groups = group_rows(@best_levels)
          suppressed_set = suppressed_indices(groups)
          released_indices = (0...@row_count).to_a - suppressed_set.to_a

          level_map = @hierarchies.each_with_index.to_h do |hierarchy, index|
            [hierarchy.key, @best_levels[index]]
          end

          rows = released_indices.map { |index| release_row(index) }
          suppressed_rows = suppressed_set.sort.map { |index| @rows[index] }
          destinations = build_destinations(groups, suppressed_set)
          rate = suppressed_set.size.to_f / @row_count

          Result.new(
            levels: level_map,
            rows: rows,
            destinations: destinations,
            suppressed_rows: suppressed_rows,
            suppressed_count: suppressed_set.size,
            suppression_rate: rate,
            loss: @best_loss,
            feasible: true,
            proven_optimal: @fully_explored,
            evaluations: @evaluations,
            total_schemes: @total_schemes
          )
        end

        # @api private
        def release_row(row_index)
          generalized = @hierarchies.each_with_index.to_h do |hierarchy, column|
            [hierarchy.key, @generalized[column][@best_levels[column]][row_index]]
          end
          @rows[row_index].merge(generalized)
        end

        # @api private
        def build_destinations(groups, suppressed_set)
          group_by_row = {}
          groups.each do |signature, indices|
            signature_map = @hierarchies.each_with_index.to_h do |hierarchy, column|
              [hierarchy.key, signature[column]]
            end
            indices.each { |index| group_by_row[index] = [signature_map, indices.size] }
          end

          @row_count.times.map do |index|
            signature, size = group_by_row[index]
            released = !suppressed_set.include?(index)
            {
              index: index,
              released: released,
              group_size: size,
              group: signature,
              loss: released ? row_loss(index) : 1.0
            }
          end
        end

        # @api private
        def row_loss(row_index)
          return 0.0 if @column_count.zero?

          sum = @column_count.times.sum do |column|
            @cell_losses[column][@best_levels[column]][row_index]
          end
          sum / @column_count.to_f
        end

        # @api private
        def all_suppressed_destinations
          @row_count.times.map do |index|
            {
              index: index,
              released: false,
              group_size: nil,
              group: nil,
              loss: 1.0
            }
          end
        end
      end
    end
  end
end
