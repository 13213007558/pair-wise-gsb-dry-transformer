# frozen_string_literal: true

module Dry
  module Transformer
    module KAnonymity
      # Generalization hierarchy defined by nested numeric intervals.
      #
      # `ranges` is an array of levels, ordered from the finest intervals to
      # the coarsest ones. Every level must be a partition of the same finite
      # domain, and fine intervals must be grouped (tiled without gaps or
      # overlaps) inside the coarse intervals of the next level.
      #
      # @example decades grouped into centuries
      #   ranges: [
      #     [0..9, 10..19, 20..29, 30..39],
      #     [0..19, 20..39]
      #   ]
      #
      # @api private
      class NumericHierarchy < Hierarchy
        # @api private
        def initialize(key, ranges)
          unless ranges.is_a?(::Array) && !ranges.empty? &&
                 ranges.all? { |level| level.is_a?(::Array) }
            raise ArgumentError,
                  "numeric hierarchy for #{key.inspect} needs an array of range-level arrays"
          end

          @key = key
          @levels_per_depth = ranges.map { |level| validate_level(key, level) }
          validate_nesting(key, @levels_per_depth)

          @levels = @levels_per_depth.size
          
          finest = @levels_per_depth.first
          @domain_span = next_boundary(finest.last) - finest.first.min

          return unless @domain_span.zero?

          raise ArgumentError, "numeric domain for #{key.inspect} must span more than one value"
        end

        # @api private
        def generalize_present(value, level)
          return value if level.zero?

          locate(value, @levels_per_depth[level - 1])
        end

        # @api private
        def loss_present(value, level)
          return 0.0 if level.zero?

          bin = locate(value, @levels_per_depth[level - 1])
          width(bin).to_f / @domain_span
        end

        private

        # @api private
        def validate_level(key, bins)
          if bins.empty?
            raise ArgumentError, "numeric hierarchy for #{key.inspect} contains an empty level"
          end

          unless bins.all? { |bin| bounded?(bin) }
            raise ArgumentError, "bins for #{key.inspect} must be bounded ranges"
          end

          excluded = bins.map(&:exclude_end?).uniq
          if excluded.size > 1
            raise ArgumentError, "bins for #{key.inspect} must all be open or all closed"
          end

          ordered = bins.sort_by(&:min)
          ordered.each_cons(2) do |left, right|
            next_start = right.min
            boundary = next_boundary(left)
            if next_start < boundary
              raise ArgumentError, "bins for #{key.inspect} overlap"
            end
            if next_start > boundary
              raise ArgumentError, "bins for #{key.inspect} leave a gap"
            end
          end
          ordered
        end

        # @api private
        def validate_nesting(key, levels)
          levels.each_cons(2) do |fine, coarse|
            coarse.each do |outer|
              covered = fine.select do |bin|
                bin.min >= outer.min && end_value(bin) <= end_value(outer)
              end
              if covered.empty?
                raise ArgumentError, "fine level for #{key.inspect} does not cover #{outer.inspect}"
              end

              first = covered.first
              last = covered.last
              unless first.min == outer.min && end_value(last) == end_value(outer)
                raise ArgumentError, "fine bins for #{key.inspect} do not tile #{outer.inspect}"
              end

              covered.each_cons(2) do |left, right|
                boundary = next_boundary(left)
                if right.min != boundary
                  raise ArgumentError, "fine bins for #{key.inspect} do not tile #{outer.inspect}"
                end
              end
            end
          end
        end

        # @api private
        def locate(value, bins)
          bin = bins.bsearch { |candidate| end_value(candidate) > value ||
            (!candidate.exclude_end? && end_value(candidate) == value) }
          if bin.nil? || !bin.cover?(value)
            raise ArgumentError,
                  "value #{value.inspect} is outside numeric domain for #{@key.inspect}"
          end

          bin
        end

        # Width of a (bounded) range.
        #
        # @api private
        def width(range)
          next_boundary(range) - range.min
        end

        # Start value of the bin immediately following `range`.
        #
        # @api private
        def next_boundary(range)
          if range.exclude_end?
            end_value(range)
          else
            end_value(range) + 1
          end
        end

        # End bound without calling `Range#max` (which Ruby refuses for
        # half-open float ranges).
        #
        # @api private
        def end_value(range)
          range.end
        end

        # @api private
        def bounded?(range)
          range.is_a?(::Range) && !range.begin.nil? && !range.end.nil?
        end
      end
    end
  end
end
