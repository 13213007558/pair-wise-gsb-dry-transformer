# frozen_string_literal: true

require "fileutils"
require "tempfile"

module Dry
  module Transformer
    module ArrayTransformations
      # Bounded, stable external sort for enumerable input.
      #
      # @api private
      class StableSort
        include Enumerable

        IDENTITY = ->(value) { value }.freeze
        DEFAULT_COMPARATOR = ->(left, right) { left <=> right }.freeze

        Rule = Struct.new(:key, :order, :null_position, :comparator)
        STOP = Object.new.freeze

        attr_reader :input, :rules, :budget, :fan_in, :temp_directory,
                    :runs_written, :merge_rounds

        def initialize(
          input,
          key: nil,
          keys: nil,
          order: :asc,
          orders: nil,
          nulls: :last,
          null_positions: nil,
          comparator: nil,
          comparators: nil,
          rules: nil,
          budget: 100,
          fan_in: 8,
          tempdir: nil
        )
          unless input.respond_to?(:each)
            raise ArgumentError, "input must respond to #each"
          end

          @input = input
          @rules = build_rules(
            rules, key, keys, order, orders, nulls, null_positions,
            comparator, comparators
          )
          @budget = Integer(budget)
          @fan_in = Integer(fan_in)
          @temp_directory = tempdir

          raise ArgumentError, "budget must be greater than 0" if @budget <= 0
          raise ArgumentError, "fan_in must be greater than 1" if @fan_in < 2

          @state = :idle
          @owned_paths = []
          @runs_written = 0
          @merge_rounds = 0
        end

        def memory_budget
          [budget, fan_in].max
        end

        def file_descriptor_budget
          fan_in + 1
        end

        def each
          return CloseableEnumerator.new(self, __method__) unless block_given?

          unless @state.equal?(:idle)
            raise IOError, "stable sort input can only be traversed once"
          end

          @state = :running
          @runs_written = 0
          @merge_rounds = 0
          run_paths = []
          entries = []
          sequence = 0
          tempdir = nil

          flush = -> {
            next if entries.empty?

            tempdir ||= create_temp_directory
            run_paths << write_run(entries, tempdir)
            entries.clear
          }

          begin
            input.each do |row|
              entries << [sequence, row, derived_keys(row)]
              sequence += 1
              flush.call if entries.size == budget
            end

            if run_paths.empty?
              sorted_entries(entries).each { |entry| yield entry[1] }
            else
              flush.call unless entries.empty?
              each_merged(run_paths, tempdir) { |entry| yield entry[1] }
            end
          ensure
            @state = :closed
            cleanup(run_paths, tempdir)
          end

          self
        end

        private

        def build_rules(
          rules, key, keys, order, orders, nulls, null_positions,
          comparator, comparators
        )
          if rules
            Array(rules).map do |rule|
              rule = {key: rule} unless rule.is_a?(::Hash)
              build_rule(
                key: rule.fetch(:key),
                order: rule.fetch(:order, rule.fetch(:direction, :asc)),
                nulls: rule.fetch(:nulls, rule.fetch(:null_position, :last)),
                comparator: rule.fetch(:comparator, rule.fetch(:compare, DEFAULT_COMPARATOR))
              )
            end
          else
            key_functions = keys.nil? ? key : keys
            key_functions = [IDENTITY] if key_functions.nil?
            key_functions = array_value(key_functions)

            key_functions.each_with_index.map do |key_function, index|
              build_rule(
                key: key_function,
                order: broadcast(orders.nil? ? order : orders, index, :asc),
                nulls: broadcast(null_positions.nil? ? nulls : null_positions, index, :last),
                comparator: broadcast(comparators.nil? ? comparator : comparators, index, DEFAULT_COMPARATOR)
              )
            end
          end
        end

        def build_rule(key:, order:, nulls:, comparator:)
          unless key.respond_to?(:call)
            raise ArgumentError, "sort key must respond to #call"
          end
          unless comparator.respond_to?(:call)
            raise ArgumentError, "comparator must respond to #call"
          end

          Rule.new(
            key,
            normalize_order(order),
            normalize_null_position(nulls),
            comparator
          )
        end

        def normalize_order(order)
          case order
          when :asc, :ascending, "asc", "ascending" then :asc
          when :desc, :descending, "desc", "descending" then :desc
          else raise ArgumentError, "order must be :asc or :desc"
          end
        end

        def normalize_null_position(position)
          case position
          when :first, :first!, "first" then :first
          when :last, :last!, "last" then :last
          else raise ArgumentError, "null position must be :first or :last"
          end
        end

        def broadcast(value, index, default)
          value = default if value.nil?
          return value unless value.is_a?(::Array)
          return value.first if value.size == 1

          value.fetch(index)
        rescue IndexError
          raise ArgumentError, "sort option has #{value.size} values for #{index + 1} keys"
        end

        def array_value(value)
          value.is_a?(::Array) ? value : [value]
        end

        def derived_keys(row)
          rules.map { |rule| rule.key.call(row) }
        end

        def sorted_entries(entries)
          entries.sort! { |left, right| compare_entries(left, right) }
        end

        def compare_entries(left, right)
          result = compare_keys(left[2], right[2])
          return result unless result.zero?

          left[0] <=> right[0]
        end

        def compare_keys(left, right)
          rules.each_with_index do |rule, index|
            result = compare_key(rule, left[index], right[index])
            return result unless result.zero?
          end

          0
        end

        def compare_key(rule, left, right)
          if left.nil? || right.nil?
            return 0 if left.nil? && right.nil?

            null_first = rule.null_position.equal?(:first)
            if left.nil?
              return null_first ? -1 : 1
            else
              return null_first ? 1 : -1
            end
          end

          result = rule.comparator.call(left, right)
          unless result.is_a?(::Integer) && result.between?(-1, 1)
            raise ArgumentError, "comparator must return -1, 0, or 1"
          end

          rule.order.equal?(:desc) ? -result : result
        end

        def each_merged(paths, tempdir)
          while paths.size > fan_in
            next_paths = []

            paths.each_slice(fan_in) do |group|
              next_paths << if group.size == 1
                              group.first
                            else
                              write_merged_run(group, tempdir)
                            end
            end

            consumed_paths = paths - next_paths
            paths = next_paths
            @merge_rounds += 1
            consumed_paths.each { |path| delete_run(path) }
          end

          readers = paths.map { |path| open_reader(path) }

          begin
            merge_readers(readers) { |entry| yield entry }
          ensure
            close_readers(readers)
          end
        end

        def write_run(entries, tempdir)
          sorted = sorted_entries(entries)
          file = create_run_file(tempdir)

          begin
            sorted.each { |entry| write_entry(file, entry) }
            file.close
          rescue StandardError
            close_and_delete(file)
            raise
          end

          own_run(file.path)
        end

        def write_merged_run(paths, tempdir)
          file = create_run_file(tempdir)
          readers = []

          begin
            readers = paths.map { |path| open_reader(path) }
            merge_readers(readers) { |entry| write_entry(file, entry) }
            file.close
          rescue StandardError
            close_and_delete(file)
            raise
          ensure
            close_readers(readers)
          end

          own_run(file.path)
        end

        def own_run(path)
          @owned_paths << path
          @runs_written += 1
          path
        end

        def create_run_file(tempdir)
          file = ::Tempfile.create("dry-transformer-run", tempdir)
          file.binmode
          file
        end

        def write_entry(file, entry)
          bytes = Marshal.dump(entry)
          file.write([bytes.bytesize].pack("Q>"))
          file.write(bytes)
        end

        def open_reader(path)
          file = File.open(path, "rb")
          {io: file, current: read_entry(file)}
        end

        def merge_readers(readers)
          readers.map! { |reader| reader[:current].nil? ? nil : reader }

          until readers.compact.empty?
            selected_index = nil

            readers.each_with_index do |reader, index|
              next unless reader
              if selected_index
                comparison = compare_entries(reader[:current], readers[selected_index][:current])
                next unless comparison.zero? ? index < selected_index : comparison.negative?
              end

              selected_index = index
            end

            selected = readers[selected_index]
            yield selected[:current]
            readers[selected_index] = advance_reader(selected)
          end
        end

        def advance_reader(reader)
          entry = read_entry(reader[:io])
          return nil if entry.nil?

          reader[:current] = entry
          reader
        end

        def read_entry(file)
          header = file.read(8)
          return nil if header.nil?

          size = header.unpack1("Q>")
          bytes = file.read(size)
          raise "truncated stable sort run file" if bytes.nil? || bytes.bytesize != size

          Marshal.load(bytes)
        end

        def close_readers(readers)
          readers.compact.each do |reader|
            reader[:io]&.close unless reader[:io].nil? || reader[:io].closed?
          end
        end

        def create_temp_directory
          @active_temp_directory = Dir.mktmpdir("dry-transformer-stable-sort", temp_directory)
        end

        def cleanup(paths, _tempdir)
          (Array(paths) + @owned_paths).uniq.each do |path|
            File.delete(path) if File.file?(path)
          rescue StandardError
            nil
          end

          @owned_paths.clear

          if @active_temp_directory
            FileUtils.remove_entry(@active_temp_directory, true)
            @active_temp_directory = nil
          end
        end

        def delete_run(path)
          File.delete(path) if File.file?(path)
          @owned_paths.delete(path)
        end

        def close_and_delete(file)
          path = file.path
          file.close unless file.closed?
          File.delete(path) if path && File.file?(path)
        rescue StandardError
          nil
        end

        # Enumerator wrapper with an explicit cleanup hook.
        #
        # @api private
        class CloseableEnumerator
          include Enumerable

          def initialize(target, method_name)
            @target = target
            @method_name = method_name
            @stopped = false
            @mutex = Mutex.new
            @fiber = nil
            @completed = false
            @error = nil
          end

          def each
            return self unless block_given?

            @target.public_send(@method_name) do |value|
              break if stopped?

              yield value
            end
            self
          rescue LocalJumpError
            self
          end

          def next
            raise StopIteration, "iteration has been closed" if @stopped

            if !@fiber && @completed
              raise StopIteration, "iteration reached an end"
            end

            result = @fiber ? resume_fiber : start_fiber

            case result
            when STOP
              @fiber = nil
              raise StopIteration, "iteration reached an end"
            when Exception
              @fiber = nil
              raise result
            else
              result
            end
          end

          def close
            @mutex.synchronize do
              return self if @stopped

              @stopped = true
              resume_fiber(STOP) if @fiber&.alive?
            end
            self
          rescue FiberError
            self
          end

          def rewind
            close
            self
          end

          def size
            nil
          end

          def inspect
            "#<#{self.class.name} target=#{@target.class} method=#{@method_name}>"
          end
          alias_method :to_s, :inspect

          private

          def stopped?
            @mutex.synchronize { @stopped }
          end

          def start_fiber
            @fiber = Fiber.new do
              begin
                @target.public_send(@method_name) do |value|
                  signal = Fiber.yield(value)
                  break if signal.equal?(STOP)
                end
                @completed = true
              rescue Exception => error
                @error = error
              ensure
                Fiber.yield(@error || STOP)
              end
            end
            resume_fiber
          end

          def resume_fiber(value = nil)
            @fiber.resume(value)
          end
        end
      end
    end
  end
end
