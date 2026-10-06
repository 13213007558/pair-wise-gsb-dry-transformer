# frozen_string_literal: true

module Dry
  module Transformer
    module KAnonymity
      # Generalization hierarchy backed by a categorical domain tree.
      #
      # The tree is given as nested hashes: leaves are `nil`, every other
      # node maps its child labels to their subtrees. All leaves must share
      # the same depth.
      #
      # @example a two-level taxonomy
      #   tree = {
      #     "Europe" => {
      #       "France" => {"Paris" => nil, "Lyon" => nil},
      #       "Germany" => {"Berlin" => nil, "Bonn" => nil}
      #     }
      #   }
      #
      # @api private
      class CategoricalHierarchy < Hierarchy
        # @api private
        def initialize(key, tree)
          @key = key
          @tree = tree
          @paths = {}
          @leaf_counts = Hash.new(0)
          @seen_labels = {}
          height = collect(tree, [], @paths, @leaf_counts)
          @levels = height - 1
          @leaf_total = @leaf_counts[root_label]

          if @leaf_total.zero?
            raise ArgumentError, "tree for #{key.inspect} has no leaves"
          end
        end

        # @api private
        def generalize_present(value, level)
          path = fetch_path(value)
          path.fetch(path.size - 1 - level) do
            raise ArgumentError, "level #{level} exceeds tree height for #{@key.inspect}"
          end
        end

        # @api private
        def loss_present(value, level)
          path = fetch_path(value)
          node = path.fetch(path.size - 1 - level) do
            raise ArgumentError, "level #{level} exceeds tree height for #{@key.inspect}"
          end
          (leaf_count(node) - 1).to_f / (@leaf_total - 1)
        end

        private

        # @api private
        def fetch_path(value)
          @paths.fetch(value) do
            raise ArgumentError,
                  "value #{value.inspect} is not present in tree for #{@key.inspect}"
          end
        end

        # @api private
        def leaf_count(node)
          @leaf_counts[node]
        end

        # @api private
        def root_label
          @tree.keys.first
        end

        # Walks the tree, recording every leaf's root-to-leaf path and the
        # number of leaves below every (non-leaf) node.
        #
        # @return [Integer] height of the tree (level 0 is the leaves)
        #
        # @api private
        def collect(node, path, paths, leaf_counts)
          unless node.is_a?(::Hash) && !node.empty?
            raise ArgumentError, "tree nodes for #{@key.inspect} must be non-empty hashes"
          end

          depths = node.map do |label, child|
            register_label(label, path)
            child_path = path + [label]

            if child.nil?
              paths[label] = child_path
              child_path.each { |ancestor| leaf_counts[ancestor] += 1 }
              next child_path.size
            end

            collect(child, child_path, paths, leaf_counts)
          end

          if depths.uniq.size > 1
            raise ArgumentError, "tree for #{@key.inspect} is not balanced (leaves at different depths)"
          end

          depths.first
        end

        # @api private
        def register_label(label, path)
          if path.include?(label)
            raise ArgumentError, "tree for #{@key.inspect} contains a cycle at #{label.inspect}"
          end

          if @seen_labels.key?(label)
            raise ArgumentError, "duplicate node label #{label.inspect} in tree for #{@key.inspect}"
          end

          @seen_labels[label] = true
        end
      end
    end
  end
end
