# frozen_string_literal: true

module Dry
  module Transformer
    # Transformation functions for Array objects
    #
    # @example
    #   require 'dry/transformer/array'
    #
    #   include Dry::Transformer::Helper
    #
    #   fn = t(:map_array, t(:symbolize_keys)) >> t(:wrap, :address, [:city, :zipcode])
    #
    #   fn.call(
    #     [
    #       { 'city' => 'Boston', 'zipcode' => '123' },
    #       { 'city' => 'NYC', 'zipcode' => '312' }
    #     ]
    #   )
    #   # => [{:address=>{:city=>"Boston", :zipcode=>"123"}},
    #   #    {:address=>{:city=>"NYC", :zipcode=>"312"}}]
    #
    # @api public
    module ArrayTransformations
      extend Registry

      # Map array values using transformation function
      #
      # @example
      #
      #   fn = Dry::Transformer(:map_array, -> v { v.upcase })
      #
      #   fn.call ['foo', 'bar'] # => ["FOO", "BAR"]
      #
      # @param [Array] array The input array
      # @param [Proc] fn The transformation function
      #
      # @return [Array]
      #
      # @api public
      def self.map_array(array, fn)
        Array(array).map { |value| fn[value] }
      end

      # Filter array values using a callable or declarative predicate
      #
      # @example
      #
      #   fn = Dry::Transformer(:filter_array, active: true)
      #   fn.call [{ active: true }, { active: false }]
      #   # => [{ active: true }]
      #
      # @param [Array] array The input array
      # @param [Proc,Symbol,Hash] predicate The predicate used for filtering
      #
      # @return [Array]
      #
      # @api public
      def self.filter_array(array, predicate)
        Array(array).select { |value| match_filter?(value, predicate) }
      end
      class << self
        alias_method :filter, :filter_array
      end

      # Wrap array values using HashTransformations.nest function
      #
      # @example
      #   fn = Dry::Transformer(:wrap, :address, [:city, :zipcode])
      #
      #   fn.call [{ city: 'NYC', zipcode: '123' }]
      #   # => [{ address: { city: 'NYC', zipcode: '123' } }]
      #
      # @param [Array] array The input array
      # @param [Object] key The nesting root key
      # @param [Object] keys The nesting value keys
      #
      # @return [Array]
      #
      # @api public
      def self.wrap(array, key, keys)
        nest = HashTransformations[:nest, key, keys]
        array.map { |element| nest.call(element) }
      end

      # Group array values using provided root key and value keys
      #
      # @example
      #   fn = Dry::Transformer(:group, :tags, [:tag])
      #
      #   fn.call [
      #     { task: 'Group it', tag: 'task' },
      #     { task: 'Group it', tag: 'important' }
      #   ]
      #   # => [{ task: 'Group it', tags: [{ tag: 'task' }, { tag: 'important' }]]
      #
      # @param [Array] array The input array
      # @param [Object] key The nesting root key
      # @param [Object] keys The nesting value keys
      #
      # @return [Array]
      #
      # @api public
      def self.group(array, key, keys)
        grouped = Hash.new { |h, k| h[k] = [] }
        array.each do |hash|
          hash = Hash[hash]

          old_group = Coercions.to_tuples(hash.delete(key))
          new_group = keys.inject({}) { |a, e| a.merge(e => hash.delete(e)) }

          grouped[hash] << old_group.map { |item| item.merge(new_group) }
        end
        grouped.map do |root, children|
          root.merge(key => children.flatten)
        end
      end

      # Aggregate array tuples with retractable count and sums
      #
      # @example
      #   fn = Dry::Transformer(
      #     :aggregate,
      #     group_by: :category,
      #     count: :items_count,
      #     sum: { total: :amount }
      #   )
      #
      #   fn.call [
      #     { category: "a", amount: 1 },
      #     { category: "a", amount: 2 }
      #   ]
      #   # => [{ category: "a", items_count: 2, total: 3 }]
      #
      # @param [Array] array The input array
      # @param [Hash] options Aggregate options
      # @option options [Object,Array,nil] :group_by Key or keys to group by
      # @option options [true,Symbol] :count Output key for row count
      # @option options [Symbol,Hash] :sum Sum output key and source key mapping
      #
      # @return [Array]
      #
      # @api public
      def self.aggregate(array, options = EMPTY_OPTIONS)
        unless options.is_a?(Hash)
          raise ArgumentError, "aggregate options must be a Hash"
        end

        group_keys = Array(options[:group_by]).compact
        count_key =
          case options[:count]
          when true then :count
          when String then options[:count].to_sym
          else options[:count]
          end
        sum_mapping = aggregate_sum_mapping(options[:sum])

        if options[:count].nil? && options[:sum].nil?
          raise ArgumentError, "aggregate requires count or sum"
        end

        buckets = Hash.new do |hash, group_key|
          hash[group_key] = {
            count: 0,
            sums: sum_mapping.to_h { |output_key, _| [output_key, 0] }
          }
        end
        order = []

        Array(array).each do |tuple|
          group_key = tuple.values_at(*group_keys)
          order << group_key unless buckets.key?(group_key)

          bucket = buckets[group_key]
          bucket[:count] += 1

          sum_mapping.each do |output_key, source_key|
            bucket[:sums][output_key] += aggregate_numeric_value(tuple, source_key)
          end
        end

        order.map do |group_key|
          tuple = group_keys.zip(group_key).to_h
          bucket = buckets[group_key]
          tuple[count_key] = bucket[:count] if count_key
          bucket[:sums].each { |output_key, value| tuple[output_key] = value }
          tuple
        end
      end

      # Ungroup array values using provided root key and value keys
      #
      # @example
      #   fn = Dry::Transformer(:ungroup, :tags, [:tag])
      #
      #   fn.call [
      #     { task: 'Group it', tags: [{ tag: 'task' }, { tag: 'important' }] }
      #   ]
      #   # => [
      #     { task: 'Group it', tag: 'task' },
      #     { task: 'Group it', tag: 'important' }
      #   ]
      #
      # @param [Array] array The input array
      # @param [Object] key The nesting root key
      # @param [Object] keys The nesting value keys
      #
      # @return [Array]
      #
      # @api public
      def self.ungroup(array, key, keys)
        array.flat_map { |item| HashTransformations.split(item, key, keys) }
      end

      def self.combine(array, mappings)
        Combine.combine(array, mappings)
      end

      # Converts the array of hashes to array of values, extracted by given key
      #
      # @example
      #   fn = t(:extract_key, :name)
      #   fn.call [
      #     { name: 'Alice', role: 'sender' },
      #     { name: 'Bob', role: 'receiver' },
      #     { role: 'listener' }
      #   ]
      #   # => ['Alice', 'Bob', nil]
      #
      # @param [Array<Hash>] array The input array of hashes
      # @param [Object] key The key to extract values by
      #
      # @return [Array]
      #
      # @api public
      def self.extract_key(array, key)
        map_array(array, ->(v) { v[key] })
      end

      # Wraps every value of the array to tuple with given key
      #
      # The transformation partially inverses the `extract_key`.
      #
      # @example
      #   fn = t(:insert_key, 'name')
      #   fn.call ['Alice', 'Bob', nil]
      #   # => [{ 'name' => 'Alice' }, { 'name' => 'Bob' }, { 'name' => nil }]
      #
      # @param [Array<Hash>] array The input array of hashes
      # @param [Object] key The key to extract values by
      #
      # @return [Array]
      #
      # @api public
      def self.insert_key(array, key)
        map_array(array, ->(v) { {key => v} })
      end

      # Adds missing keys with nil value to all tuples in array
      #
      # @param [Array] keys
      #
      # @return [Array]
      #
      # @api public
      #
      def self.add_keys(array, keys)
        base = keys.inject({}) { |a, e| a.merge(e => nil) }
        map_array(array, ->(v) { base.merge(v) })
      end

      # @api private
      EMPTY_OPTIONS = {}.freeze

      # @api private
      def self.match_filter?(value, predicate)
        case predicate
        when Proc then predicate.call(value)
        when Symbol then !value[predicate].nil? && value[predicate] != false
        when Hash
          predicate.all? do |key, expected|
            value.is_a?(::Hash) && value.key?(key) && value[key] == expected
          end
        else
          raise ArgumentError, "filter predicate must be a Proc, Symbol, or Hash"
        end
      end

      # @api private
      def self.aggregate_sum_mapping(sum)
        case sum
        when nil then {}
        when Symbol then {sum => sum}
        when String then {sum.to_sym => sum}
        when Hash then sum.transform_keys(&:to_sym)
        else
          raise ArgumentError, "sum must be a key name or a key mapping"
        end
      end

      # @api private
      def self.aggregate_numeric_value(tuple, source_key)
        value = tuple[source_key]
        return 0 if value.nil?
        return value if value.is_a?(Numeric)

        raise TypeError, "cannot sum non-numeric value #{value.inspect} for #{source_key.inspect}"
      end

      private_class_method :match_filter?, :aggregate_sum_mapping, :aggregate_numeric_value
    end
  end
end
