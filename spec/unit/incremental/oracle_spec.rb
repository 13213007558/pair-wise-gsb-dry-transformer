# frozen_string_literal: true

# Step-by-step oracle: a long sequence of mixed add / remove / update events
# is applied to an incremental session, and after every batch the result is
# compared against re-executing the whole pipeline from scratch. Deltas are
# also replayed onto the previous result to prove they are sufficient.
RSpec.describe 'incremental session oracle' do
  NAMES = %w[jane john bob].freeze
  CITIES = %w[NYC LA SF].freeze

  def random_row(rng, id)
    {
      id: id,
      user_name: NAMES[rng.rand(NAMES.size)],
      active: rng.rand < 0.7,
      city: CITIES[rng.rand(CITIES.size)],
      amount: rng.rand(21)
    }
  end

  # Builds a batch of 1-4 mixed events and applies them to the mirror rows
  def random_batch(rng, rows, next_id)
    batch = []
    rng.rand(1..4).times do
      ids = rows.keys
      roll = rng.rand

      if ids.empty? || roll < 0.4
        row = random_row(rng, next_id)
        next_id += 1
        rows[row[:id]] = row
        batch << {type: :add, row: row}
      elsif roll < 0.75
        id = ids[rng.rand(ids.size)]
        if rng.rand < 0.5
          row = random_row(rng, id)
          rows[id] = row
          batch << {type: :update, id: id, row: row}
        else
          changes = {}
          changes[:active] = !rows[id][:active] if rng.rand < 0.5
          changes[:city] = CITIES[rng.rand(CITIES.size)] if rng.rand < 0.5
          changes[:amount] = rng.rand(21) if rng.rand < 0.5
          rows[id] = rows[id].merge(changes)
          batch << {type: :update, id: id, changes: changes}
        end
      else
        id = ids[rng.rand(ids.size)]
        rows.delete(id)
        batch << {type: :remove, id: id}
      end
    end
    [batch, next_id]
  end

  def apply_delta(result, delta)
    out = result.dup
    delta.removed.each_key { |key| out.delete(key) }
    delta.added.each { |key, value| out[key] = value }
    entries = delta.respond_to?(:updated) ? delta.updated : delta.changed
    entries.each { |key, (_before, after)| out[key] = after }
    out
  end

  # Independent from-scratch reference implementations

  def reference_rows(rows)
    rows.each_with_object({}) do |(id, row), out|
      renamed = row.dup
      renamed[:name] = renamed.delete(:user_name) if renamed.key?(:user_name)
      next unless renamed[:active]

      out[id] = renamed.merge(upper: renamed[:name].upcase)
    end
  end

  def reference_groups(rows)
    rows.each_with_object({}) do |(_id, row), groups|
      next unless row[:active]

      acc = groups[row[:city]] ||= {sum_amount: 0, count: 0}
      acc[:sum_amount] += row[:amount] || 0
      acc[:count] += 1
    end
  end

  def reference_max(rows)
    rows.each_with_object({}) do |(_id, row), groups|
      next unless row[:active]

      acc = groups[row[:city]] ||= {max_amount: row[:amount]}
      acc[:max_amount] = row[:amount] if row[:amount] > acc[:max_amount]
    end
  end

  shared_examples 'a mixed-update oracle' do |session, reference|
    it 'tracks full re-execution step by step' do
      rng = Random.new(20261006)
      rows = {}
      next_id = 1
      previous = {}

      200.times do
        batch, next_id = random_batch(rng, rows, next_id)
        delta = session.apply(batch)
        expected = send(reference, rows)

        expect(session.result).to eq(expected)
        expect(apply_delta(previous, delta)).to eq(expected)
        previous = expected
      end

      expect(rows).not_to be_empty
    end
  end

  context 'with a rename / filter / map pipeline' do
    it_behaves_like 'a mixed-update oracle',
                    Dry::Transformer::Incremental::Session.new(id: :id) { |t|
                      t.rename user_name: :name
                      t.filter { |row| row[:active] }
                      t.map { |row| row.merge(upper: row[:name].upcase) }
                    },
                    :reference_rows
  end

  context 'with a filter / group pipeline' do
    it_behaves_like 'a mixed-update oracle',
                    Dry::Transformer::Incremental::Session.new(id: :id) { |t|
                      t.filter { |row| row[:active] }
                      t.group :city do |g|
                        g.sum :amount
                        g.count
                      end
                    },
                    :reference_groups
  end

  context 'with a non-retractable aggregation in recompute mode' do
    it_behaves_like 'a mixed-update oracle',
                    Dry::Transformer::Incremental::Session.new(id: :id, on_unsupported: :recompute) { |t|
                      t.filter { |row| row[:active] }
                      t.group(:city) { |g| g.aggregate(:max, :amount) }
                    },
                    :reference_max
  end
end
