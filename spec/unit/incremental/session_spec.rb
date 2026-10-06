# frozen_string_literal: true

RSpec.describe Dry::Transformer::Incremental::Session do
  describe 'row-oriented pipeline (rename / filter / map)' do
    subject(:session) do
      described_class.new(id: :id) do |t|
        t.rename user_name: :name
        t.filter { |row| row[:active] }
        t.map { |row| row.merge(upper: row[:name].upcase) }
      end
    end

    it 'emits added rows for the initial batch' do
      delta = session.apply([
        {type: :add, row: {id: 1, user_name: 'jane', active: true}},
        {type: :add, row: {id: 2, user_name: 'john', active: false}}
      ])

      expect(delta).to be_a(Dry::Transformer::Incremental::RowDelta)
      expect(delta.added).to eq(1 => {id: 1, name: 'jane', active: true, upper: 'JANE'})
      expect(delta.removed).to be_empty
      expect(delta.updated).to be_empty
      expect(session.result).to eq(delta.added)
    end

    it 'keeps rows with identical content but different ids apart' do
      session.apply([
        {type: :add, row: {id: 1, user_name: 'jane', active: true}},
        {type: :add, row: {id: 2, user_name: 'jane', active: true}}
      ])

      expect(session.result.keys).to contain_exactly(1, 2)

      delta = session.apply([{type: :remove, id: 1}])

      expect(delta.removed.keys).to eq([1])
      expect(session.result.keys).to eq([2])
    end

    it 'emits an addition when an update makes a row pass the filter' do
      session.apply([{type: :add, row: {id: 1, user_name: 'jane', active: false}}])

      delta = session.apply([{type: :update, id: 1, changes: {active: true}}])

      expect(delta.added).to eq(1 => {id: 1, name: 'jane', active: true, upper: 'JANE'})
      expect(session.result).to eq(delta.added)
    end

    it 'emits a removal when an update makes a row fail the filter' do
      session.apply([{type: :add, row: {id: 1, user_name: 'jane', active: true}}])

      delta = session.apply([{type: :update, id: 1, changes: {active: false}}])

      expect(delta.removed).to eq(1 => {id: 1, name: 'jane', active: true, upper: 'JANE'})
      expect(session.result).to be_empty
    end

    it 'emits before/after pairs for updated rows' do
      session.apply([{type: :add, row: {id: 1, user_name: 'jane', active: true}}])

      delta = session.apply([
        {type: :update, id: 1, row: {id: 1, user_name: 'jane', active: true, extra: 1}}
      ])

      expect(delta.updated).to eq(
        1 => [
          {id: 1, name: 'jane', active: true, upper: 'JANE'},
          {id: 1, name: 'jane', active: true, extra: 1, upper: 'JANE'}
        ]
      )
    end

    it 'emits an empty delta for a no-op update' do
      session.apply([{type: :add, row: {id: 1, user_name: 'jane', active: true}}])

      delta = session.apply([{type: :update, id: 1, changes: {active: true}}])

      expect(delta).to be_empty
    end

    it 'nets out a row added and removed within the same batch' do
      delta = session.apply([
        {type: :add, row: {id: 1, user_name: 'jane', active: true}},
        {type: :remove, id: 1}
      ])

      expect(delta).to be_empty
      expect(session.result).to be_empty
    end
  end

  describe 'grouped pipeline (filter / group with sum + count)' do
    subject(:session) do
      described_class.new(id: :id) do |t|
        t.filter { |row| row[:active] }
        t.group :city do |g|
          g.sum :amount
          g.count
        end
      end
    end

    it 'aggregates rows per group' do
      delta = session.apply([
        {type: :add, row: {id: 1, active: true, city: 'NYC', amount: 10}},
        {type: :add, row: {id: 2, active: true, city: 'NYC', amount: 5}},
        {type: :add, row: {id: 3, active: false, city: 'LA', amount: 7}}
      ])

      expect(delta).to be_a(Dry::Transformer::Incremental::GroupDelta)
      expect(delta.added).to eq('NYC' => {sum_amount: 15, count: 2})
      expect(session.result).to eq('NYC' => {sum_amount: 15, count: 2})
    end

    it 'counts rows with identical content but different ids separately' do
      session.apply([
        {type: :add, row: {id: 1, active: true, city: 'NYC', amount: 10}},
        {type: :add, row: {id: 2, active: true, city: 'NYC', amount: 10}}
      ])

      expect(session.result).to eq('NYC' => {sum_amount: 20, count: 2})

      session.apply([{type: :remove, id: 1}])

      expect(session.result).to eq('NYC' => {sum_amount: 10, count: 1})
    end

    it 'touches both groups when one update moves a row between them' do
      session.apply([
        {type: :add, row: {id: 1, active: true, city: 'NYC', amount: 10}},
        {type: :add, row: {id: 2, active: true, city: 'NYC', amount: 4}},
        {type: :add, row: {id: 3, active: true, city: 'LA', amount: 5}}
      ])

      delta = session.apply([{type: :update, id: 1, changes: {city: 'LA'}}])

      expect(delta.changed).to eq(
        'NYC' => [{sum_amount: 14, count: 2}, {sum_amount: 4, count: 1}],
        'LA' => [{sum_amount: 5, count: 1}, {sum_amount: 15, count: 2}]
      )
      expect(session.result).to eq(
        'NYC' => {sum_amount: 4, count: 1},
        'LA' => {sum_amount: 15, count: 2}
      )
    end

    it 'removes the old group and adds the new one when a moved row empties its group' do
      session.apply([{type: :add, row: {id: 1, active: true, city: 'NYC', amount: 10}}])

      delta = session.apply([{type: :update, id: 1, changes: {city: 'LA'}}])

      expect(delta.removed).to eq('NYC' => {sum_amount: 10, count: 1})
      expect(delta.added).to eq('LA' => {sum_amount: 10, count: 1})
      expect(session.result).to eq('LA' => {sum_amount: 10, count: 1})
    end

    it 'retracts sums and counts when rows are removed' do
      session.apply([
        {type: :add, row: {id: 1, active: true, city: 'NYC', amount: 10}},
        {type: :add, row: {id: 2, active: true, city: 'NYC', amount: 5}}
      ])

      delta = session.apply([{type: :remove, id: 1}])

      expect(delta.changed).to eq('NYC' => [{sum_amount: 15, count: 2}, {sum_amount: 5, count: 1}])
    end

    it 'removes a group when its last member leaves' do
      session.apply([{type: :add, row: {id: 1, active: true, city: 'NYC', amount: 10}}])

      delta = session.apply([{type: :remove, id: 1}])

      expect(delta.removed).to eq('NYC' => {sum_amount: 10, count: 1})
      expect(session.result).to be_empty
    end

    it 'retracts a row from its group when an update makes it fail the filter' do
      session.apply([{type: :add, row: {id: 1, active: true, city: 'NYC', amount: 10}}])

      delta = session.apply([{type: :update, id: 1, changes: {active: false}}])

      expect(delta.removed).to eq('NYC' => {sum_amount: 10, count: 1})
      expect(session.result).to be_empty
    end

    it 'supports composite group keys and custom aggregate names' do
      grouped = described_class.new(id: :id) do |t|
        t.group %i[city kind] do |g|
          g.sum :amount, as: :total
          g.count as: :n
        end
      end

      grouped.apply([
        {type: :add, row: {id: 1, city: 'NYC', kind: 'a', amount: 3}},
        {type: :add, row: {id: 2, city: 'NYC', kind: 'b', amount: 4}},
        {type: :add, row: {id: 3, city: 'NYC', kind: 'a', amount: 5}}
      ])

      expect(grouped.result).to eq(
        ['NYC', 'a'] => {total: 8, n: 2},
        ['NYC', 'b'] => {total: 4, n: 1}
      )
    end
  end

  describe 'unsupported transformations' do
    it 'rejects arbitrary collection-level procs' do
      expect {
        described_class.new { |t| t.transform(-> rows { rows.sort_by { |row| row[:id] } }) }
      }.to raise_error(Dry::Transformer::UnsupportedTransformError, /arbitrary/)
    end

    it 'rejects non-retractable aggregations by default' do
      expect {
        described_class.new { |t| t.group(:city) { |g| g.aggregate(:max, :amount) } }
      }.to raise_error(Dry::Transformer::UnsupportedTransformError, /recompute/)
    end

    it 'rejects unknown on_unsupported options' do
      expect {
        described_class.new(on_unsupported: :ignore) { |t| t }
      }.to raise_error(ArgumentError, /on_unsupported/)
    end

    it 'rejects stages after a group stage' do
      expect {
        described_class.new do |t|
          t.group(:city) { |g| g.count }
          t.map { |row| row }
        end
      }.to raise_error(Dry::Transformer::Error, /group/)
    end

    context 'with on_unsupported: :recompute' do
      subject(:session) do
        described_class.new(id: :id, on_unsupported: :recompute) do |t|
          t.filter { |row| row[:active] }
          t.group :city do |g|
            g.aggregate(:max, :amount)
          end
        end
      end

      it 'degrades to full recomputation' do
        expect(session).not_to be_incremental

        delta = session.apply([
          {type: :add, row: {id: 1, active: true, city: 'NYC', amount: 7}},
          {type: :add, row: {id: 2, active: true, city: 'NYC', amount: 3}}
        ])
        expect(delta.added).to eq('NYC' => {max_amount: 7})

        delta = session.apply([{type: :remove, id: 1}])
        expect(delta.changed).to eq('NYC' => [{max_amount: 7}, {max_amount: 3}])
        expect(session.result).to eq('NYC' => {max_amount: 3})
      end
    end
  end

  describe 'event validation' do
    subject(:session) { described_class.new(id: :id) { |t| t.filter { |row| row[:active] } } }

    it 'rejects duplicate adds' do
      session.apply([{type: :add, row: {id: 1, active: true}}])

      expect { session.apply([{type: :add, row: {id: 1, active: true}}]) }
        .to raise_error(Dry::Transformer::InvalidEventError, /duplicate/)
    end

    it 'rejects removes and updates of unknown ids' do
      expect { session.apply([{type: :remove, id: 1}]) }
        .to raise_error(Dry::Transformer::InvalidEventError, /unknown/)
      expect { session.apply([{type: :update, id: 1, changes: {}}]) }
        .to raise_error(Dry::Transformer::InvalidEventError, /unknown/)
    end

    it 'rejects rows without the id key' do
      expect { session.apply([{type: :add, row: {active: true}}]) }
        .to raise_error(Dry::Transformer::InvalidEventError, /id key/)
    end

    it 'rejects updates that change the row id' do
      session.apply([{type: :add, row: {id: 1, active: true}}])

      expect { session.apply([{type: :update, id: 1, row: {id: 2, active: true}}]) }
        .to raise_error(Dry::Transformer::InvalidEventError, /stable id/)
      expect { session.apply([{type: :update, id: 1, changes: {id: 2}}]) }
        .to raise_error(Dry::Transformer::InvalidEventError, /row id/)
    end

    it 'rejects unknown event types and malformed events' do
      expect { session.apply([{type: :upsert, row: {id: 1}}]) }
        .to raise_error(Dry::Transformer::InvalidEventError, /unknown event type/)
      expect { session.apply([{type: :add}]) }
        .to raise_error(Dry::Transformer::InvalidEventError, /malformed/)
    end
  end
end
