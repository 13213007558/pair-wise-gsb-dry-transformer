# frozen_string_literal: true

module Dry
  module Transformer
    module Incremental
      # Compiles a declarative transproc AST into incrementally supported steps
      #
      # @api private
      class Compiler
        TERMINAL_FUNCTIONS = %i[group aggregate].freeze
        ROW_MAPPING_FUNCTIONS = %i[
          rename_keys symbolize_keys stringify_keys map_value map_values
        ].freeze

        attr_reader :nodes, :terminal

        def initialize(ast)
          @nodes = normalize(ast)
          validate!
          @terminal = nodes.find { |name, _| TERMINAL_FUNCTIONS.include?(name) }
        end

        def terminal?
          !terminal.nil?
        end

        def pre_terminal(row)
          nodes_before_terminal.reduce(row.dup) do |current, (name, args)|
            case name
            when :map_array then apply_mapping(current, args)
            when :filter_array, :filter
              next current if match_filter?(current, args[0])

              nil
            else
              current
            end
          end
        end

        def group_options
          return unless terminal&.first == :group

          args = terminal[1]
          {key: args[0], keys: Array(args[1])}
        end

        def aggregate_options
          return unless terminal&.first == :aggregate

          options = terminal[1][0] || {}
          group_keys = Array(options[:group_by]).compact
          count_key =
            case options[:count]
            when true then :count
            when String then options[:count].to_sym
            else options[:count]
            end
          sum_mapping = aggregate_sum_mapping(options[:sum])

          {
            group_keys: group_keys,
            count_key: count_key,
            sum_mapping: sum_mapping,
            measure_keys: [count_key, *sum_mapping.keys].compact
          }
        end

        private

        def normalize(ast)
          reject_procs!(ast)
          nodes = parse_sequence(ast)
          nodes.map do |node|
            next node if supported_node?(node)

            raise UnsupportedTransformationError,
                  "incremental sessions support only map_array, filter_array, group, and aggregate"
          end
        end

        def parse_sequence(value)
          value = value[1] if value.is_a?(Array) && value.first == :t

          return [] if value.nil?
          unless value.is_a?(Array)
            raise UnsupportedTransformationError,
                  "incremental sessions support only map_array, filter_array, group, and aggregate"
          end
          raise_unsupported_shape unless value.first.is_a?(Symbol)

          nodes = []
          index = 0

          while index < value.size
            if value[index].is_a?(Symbol) && value[index + 1].is_a?(Array)
              name = value[index]
              args = value[index + 1]
              parsed_args = name == :map_array ? [parse_mapping(args[0])] : args
              nodes << [name, parsed_args]
              index += 2
            elsif value[index].is_a?(Array)
              nodes.concat(parse_sequence(value[index]))
              index += 1
            else
              raise_unsupported_shape
            end
          end

          nodes
        end

        def parse_mapping(value)
          return [] if value.nil?
          value = value[1] if value.is_a?(Array) && value.first == :t
          parse_sequence(value)
        end

        def raise_unsupported_shape
          raise UnsupportedTransformationError,
                "incremental sessions support only map_array, filter_array, group, and aggregate"
        end

        def supported_node?(node)
          return false unless node.is_a?(Array)

          name, args = node
          return false unless name.is_a?(Symbol)

          case name
          when :map_array then valid_map?(args)
          when :filter_array, :filter then valid_filter?(args)
          when :group then valid_group?(args)
          when :aggregate then valid_aggregate?(args)
          else false
          end
        end

        def validate!
          seen_terminal = false

          nodes.each do |name, _|
            if seen_terminal
              raise UnsupportedTransformationError,
                    "#{name} cannot follow a terminal group or aggregate"
            end

            seen_terminal = TERMINAL_FUNCTIONS.include?(name)
          end
        end

        def nodes_before_terminal
          if terminal
            terminal_index = nodes.index { |name, _| TERMINAL_FUNCTIONS.include?(name) }
            nodes[0...terminal_index]
          else
            nodes
          end
        end

        def valid_map?(args)
          nodes = mapping_nodes(args)
          if nodes.empty?
            raise UnsupportedTransformationError,
                  "incremental sessions cannot derive updates from a Proc"
          end

          nodes.all? { |node| valid_mapping_node?(node) }
        end

        def valid_filter?(args)
          predicate = args[0]
          return true if predicate.is_a?(Hash) || predicate.is_a?(Symbol)

          raise UnsupportedTransformationError,
                "incremental filters require a Hash equality predicate or a key Symbol"
        end

        def valid_group?(args)
          key, keys = args
          (key.is_a?(Symbol) || key.is_a?(String)) &&
            Array(keys).all? { |item| item.is_a?(Symbol) || item.is_a?(String) }
        end

        def valid_aggregate?(args)
          options = args[0]
          return false unless options.is_a?(Hash)

          valid_aggregate_group_keys?(options[:group_by]) &&
            valid_aggregate_count?(options[:count]) &&
            valid_aggregate_sum?(options[:sum]) &&
            (!options[:count].nil? || !options[:sum].nil?)
        end

        def valid_aggregate_group_keys?(group_by)
          group_by.nil? ||
            group_by.is_a?(Symbol) ||
            group_by.is_a?(String) ||
            (group_by.is_a?(Array) && group_by.all? { |key| key.is_a?(Symbol) || key.is_a?(String) })
        end

        def valid_aggregate_count?(count)
          count.nil? || count == true || count.is_a?(Symbol) || count.is_a?(String)
        end

        def valid_aggregate_sum?(sum)
          case sum
          when nil, Symbol, String then true
          when Hash then sum.keys.all? { |key| key.is_a?(Symbol) || key.is_a?(String) }
          else false
          end
        end

        def mapping_nodes(args)
          Array(args[0])
        end

        def apply_mapping(row, args)
          mapping_nodes(args).reduce(row) do |current, node|
            name, mapping_args = node

            case name
            when :rename_keys
              HashTransformations.rename_keys(current, mapping_args[0])
            when :symbolize_keys then HashTransformations.symbolize_keys(current)
            when :stringify_keys then HashTransformations.stringify_keys(current)
            when :map_value
              key, function_node = mapping_args
              HashTransformations.map_value(current, key, compile_scalar_function(function_node))
            when :map_values
              function_node = mapping_args[0]
              HashTransformations.map_values(current, compile_scalar_function(function_node))
            else
              raise UnsupportedTransformationError, "unsupported incremental mapping #{name}"
            end
          end
        end

        def valid_mapping_node?(node)
          return false unless node.is_a?(Array)

          name, args = node
          return false unless name.is_a?(Symbol)
          return ROW_MAPPING_FUNCTIONS.include?(name) if %i[
            rename_keys symbolize_keys stringify_keys
          ].include?(name)

          case name
          when :map_value
            key, function = args
            valid_mapping_key?(key) && valid_scalar_function?(function)
          when :map_values
            valid_scalar_function?(args[0])
          else
            raise UnsupportedTransformationError,
                  "incremental map_array supports only #{ROW_MAPPING_FUNCTIONS.join(", ")}"
          end
        end

        def valid_mapping_key?(key)
          key.is_a?(Symbol) || key.is_a?(String)
        end

        def valid_scalar_function?(node)
          return false unless node.is_a?(Array) && node.size == 2

          name, args = node
          name.is_a?(Symbol) && args.is_a?(Array) && args.empty? && Coercions.respond_to?(name)
        end

        def compile_scalar_function(node)
          unless valid_scalar_function?(node)
            raise UnsupportedTransformationError,
                  "incremental map values require an argument-free Dry::Transformer::Coercions function"
          end

          Coercions[node.first]
        end

        def match_filter?(row, predicate)
          case predicate
          when Symbol then row.is_a?(Hash) && !row[predicate].nil? && row[predicate] != false
          when Hash
            row.is_a?(Hash) && predicate.all? { |key, value| row.key?(key) && row[key] == value }
          else
            raise UnsupportedTransformationError, "unsupported incremental filter"
          end
        end

        def aggregate_sum_mapping(sum)
          case sum
          when nil then {}
          when Symbol then {sum => sum}
          when String then {sum.to_sym => sum}
          when Hash then sum.transform_keys(&:to_sym)
          else
            raise UnsupportedTransformationError, "unsupported incremental sum"
          end
        end

        def reject_procs!(value)
          case value
          when Proc
            raise UnsupportedTransformationError,
                  "incremental sessions cannot derive updates from a Proc"
          when Array then value.each { |item| reject_procs!(item) }
          when Hash then value.each_value { |item| reject_procs!(item) }
          end
        end
      end
    end
  end
end
