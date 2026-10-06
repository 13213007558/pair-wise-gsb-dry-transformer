# frozen_string_literal: true

RSpec.describe Dry::Transformer::Incremental::Session do
  let(:registry) do
    Module.new do
      extend Dry::Transformer::Registry

      import Dry::Transformer::ArrayTransformations
      import Dry::Transformer::HashTransformations
      import Dry::Transformer::Coercions
    end
  end

  def pipe_class(&block)
    Class.new(Dry::Transformer[registry]) do
      define!(&block)
    end
  end

  def source_rows(session)
    session.rows.map { |row| row.reject { |key| key == session.id_key } }
  end

  def aggregate_delta(before, after, group_keys, measure_keys)
    group_keys = Array(group_keys)
    before_index = before.to_h { |row| [row.values_at(*group_keys), row] }
    after_index = after.to_h { |row| [row.values_at(*group_keys), row] }

    {
      inserted: after.reject { |row| before_index.key?(row.values_at(*group_keys)) },
      updated: after.select { |row|
        previous = before_index[row.values_at(*group_keys)]
        previous && previous != row
      },
      deleted: before.reject { |row| after_index.key?(row.values_at(*group_keys)) }
    }
  end

  def group_delta(before, after, group_key)
    before_index = before.to_h { |row| [row.reject { |key| key == group_key }, row] }
    after_index = after.to_h { |row| [row.reject { |key| key == group_key }, row] }

    {
      inserted: after.reject { |row|
        before_index.key?(row.reject { |key| key == group_key })
      },
      updated: after.select { |row|
        previous = before_index[row.reject { |key| key == group_key }]
        previous && previous != row
      },
      deleted: before.reject { |row|
        after_index.key?(row.reject { |key| key == group_key })
      }
    }
  end

  def row_delta(before, after, id_key)
    before_index = before.to_h { |row| [row[id_key], row] }
    after_index = after.to_h { |row| [row[id_key], row] }

    {
      inserted: after.reject { |row| before_index.key?(row[id_key]) },
      updated: after.select { |row|
        previous = before_index[row[id_key]]
        previous && previous != row
      },
      deleted: before.reject { |row| after_index.key?(row[id_key]) }
    }
  end

  describe "retractable sum and count aggregates" do
    subject(:session) { pipe.incremental_session(rows) }

    let(:pipe) do
      pipe_class do
        map_array do
          symbolize_keys
          rename_keys kind: :category
          map_value :amount, t(:to_integer)
        end

        filter_array(active: true)
        aggregate group_by: :category, count: :count, sum: {total: :amount}
      end.new
    end

    let(:rows) do
      [
        {id: 1, "kind" => "books", "amount" => "1", "active" => true},
        {id: 2, "kind" => "books", "amount" => "1", "active" => true},
        {id: 3, "kind" => "music", "amount" => "4", "active" => false},
        {id: 4, "kind" => "games", "amount" => "5", "active" => true}
      ]
    end

    let(:events) do
      [
        {id: 3, changes: {"active" => true}},
        {op: :insert, id: 5, row: {"kind" => "books", "amount" => "2", "active" => true}},
        {id: 4, changes: {"kind" => "books"}},
        {id: 2, changes: {"active" => false}},
        {op: :delete, id: 1},
        {id: 5, changes: {"amount" => "3"}}
      ]
    end

    it "matches a full pipeline rerun after every mixed event" do
      expect(session.result).to eql(pipe.call(source_rows(session)))

      events.each do |event|
        before = pipe.call(source_rows(session))
        delta = session.call(event)
        after = pipe.call(source_rows(session))

        expect(session.result).to eql(after)
        expect(delta).to eql(aggregate_delta(before, after, :category, %i[count total]))
      end

      expect(session.result).to eql([
        {category: "music", count: 1, total: 4},
        {category: "books", count: 2, total: 8}
      ])
    end

    it "keeps duplicate rows with different IDs in the count" do
      expect(session.result).to include(
        category: "books", count: 2, total: 2
      )
    end
  end

  describe "grouping" do
    subject(:session) { pipe.incremental_session(rows) }

    let(:pipe) do
      pipe_class do
        map_array do
          symbolize_keys
          rename_keys sku_code: :sku
        end

        filter_array(active: true)
        group :items, %i[id sku]
      end.new
    end

    let(:rows) do
      [
        {id: 1, category: "books", sku_code: "A", active: true},
        {id: 2, category: "books", sku_code: "A", active: true},
        {id: 3, category: "books", sku_code: "B", active: true},
        {id: 4, category: "music", sku_code: "C", active: false}
      ]
    end

    let(:events) do
      [
        {id: 4, changes: {active: true}},
        {id: 1, changes: {sku_code: "Z"}},
        {id: 3, changes: {category: "music"}},
        {op: :delete, id: 2}
      ]
    end

    it "preserves duplicate children and updates both affected groups" do
      expect(session.result).to eql(pipe.call(session.rows))

      events.each do |event|
        before = pipe.call(session.rows)
        delta = session.call(event)
        after = pipe.call(session.rows)

        expect(session.result).to eql(after)
        expect(delta).to eql(group_delta(before, after, :items))
      end

      expect(session.result).to eql([
        {
          category: "books",
          active: true,
          items: [{id: 1, sku: "Z"}]
        },
        {
          category: "music",
          active: true,
          items: [{id: 3, sku: "B"}, {id: 4, sku: "C"}]
        }
      ])
    end
  end

  describe "map and filter rows" do
    subject(:session) { pipe.incremental_session(rows) }

    let(:pipe) do
      pipe_class do
        map_array do
          symbolize_keys
          rename_keys display_name: :name
          map_value :age, t(:to_integer)
        end

        filter_array(active: true)
      end.new
    end

    let(:rows) do
      [
        {id: 1, "display_name" => "Jane", "age" => "20", "active" => true},
        {id: 2, "display_name" => "Jane", "age" => "20", "active" => false},
        {id: 3, "display_name" => "John", "age" => "30", "active" => true}
      ]
    end

    let(:events) do
      [
        {op: :insert, id: 4, row: {"display_name" => "Jade", "age" => "40", "active" => false}},
        {id: 4, changes: {active: true}},
        {id: 4, changes: {age: "41"}},
        {id: 1, changes: {active: false}},
        {op: :delete, id: 2},
        {id: 4, changes: {active: false}},
        {id: 4, changes: {active: true}}
      ]
    end

    it "matches full row output and reports no delta while hidden" do
      expect(session.result).to eql(pipe.call(session.rows))

      events.each do |event|
        before = pipe.call(session.rows)
        delta = session.call(event)
        after = pipe.call(session.rows)

        expect(session.result).to eql(after)
        expect(delta).to eql(row_delta(before, after, :id))
      end

      expect(session.result).to eql([
        {id: 3, name: "John", age: 30, active: true},
        {id: 4, name: "Jade", age: 41, active: true}
      ])
    end
  end

  describe "unsupported transformations" do
    it "rejects a Proc inside map_array" do
      pipe = pipe_class do
        map_array(&:to_s)
      end.new

      expect {
        pipe.incremental_session([])
      }.to raise_error(
        Dry::Transformer::Incremental::UnsupportedTransformationError,
        /cannot derive updates from a Proc/
      )
    end

    it "rejects a Proc filter" do
      pipe = pipe_class do
        filter_array(->(row) { row[:active] })
      end.new

      expect {
        pipe.incremental_session([])
      }.to raise_error(
        Dry::Transformer::Incremental::UnsupportedTransformationError,
        /cannot derive updates from a Proc/
      )
    end

    it "rejects stable ID updates" do
      pipe = pipe_class do
        filter_array(active: true)
      end.new

      session = pipe.incremental_session([{id: 1, active: true}])

      expect {
        session.call(id: 1, changes: {id: 2})
      }.to raise_error(Dry::Transformer::Incremental::InvalidEventError, /stable/)
    end
  end

  describe "custom stable ID key" do
    it "reads events with the configured key" do
      pipe = pipe_class do
        filter_array(active: true)
      end.new
      session = pipe.incremental_session(
        [{row_id: 1, active: true}],
        id_key: :row_id
      )

      delta = session.call([
        {op: :insert, row_id: 2, row: {row_id: 2, active: true}},
        {row_id: 1, changes: {active: false}},
        {row_id: 2, changes: {active: false}}
      ])

      expect(session.result).to eq([])
      expect(delta).to eql(inserted: [], updated: [], deleted: [
        {row_id: 1, active: true}
      ])
    end
  end

  describe "filter alias" do
    it "supports the short declarative filter node" do
      pipe = pipe_class do
        filter :active
      end.new
      session = pipe.incremental_session([
        {id: 1, active: true},
        {id: 2, active: false}
      ])

      expect(session.result).to eql([{id: 1, active: true}])
      expect(session.call(id: 2, changes: {active: true})).to eql(
        inserted: [{id: 2, active: true}],
        updated: [],
        deleted: []
      )
    end
  end
end
