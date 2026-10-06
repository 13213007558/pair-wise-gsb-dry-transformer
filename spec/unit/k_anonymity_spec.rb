# frozen_string_literal: true

RSpec.describe Dry::Transformer::KAnonymity do
  # Independent brute-force reference used to check optimality on small tables
  def bf_chain_depth(parents, value, seen = {})
    return 0 if seen[value] || !parents.key?(value)

    seen[value] = true
    1 + bf_chain_depth(parents, parents[value], seen)
  end

  def bf_generalize_cat(parents, value, level)
    level.times.reduce(value) { |current, *| parents.fetch(current, current) }
  end

  def bf_generalize_num(edges, value)
    return nil if value.nil?

    index = edges.rindex { |edge| value >= edge }
    if index.nil?
      "<#{edges.first}"
    elsif index == edges.size - 1
      ">=#{edges.last}"
    else
      "#{edges[index]}-#{edges[index + 1]}"
    end
  end

  def bf_max_levels(fields, cat:, num:)
    fields.map do |field|
      if num.key?(field)
        num[field].size
      else
        parents = cat.fetch(field, {})
        parents.keys.map { |value| bf_chain_depth(parents, value) }.max || 0
      end
    end
  end

  def bf_key(row, fields, scheme, cat:, num:)
    fields.each_with_index.map do |field, index|
      value = row[field]
      if num.key?(field)
        scheme[index].zero? ? value : bf_generalize_num(num[field][scheme[index] - 1], value)
      else
        bf_generalize_cat(cat.fetch(field, {}), value, scheme[index])
      end
    end
  end

  # @return [Hash] loss per feasible scheme vector
  def bf_enumerate(rows, fields, k, max_suppressed, cat:, num:)
    max_levels = bf_max_levels(fields, cat: cat, num: num)
    denominator = max_levels.count(&:positive?)
    losses = {}
    level_ranges = max_levels.map { |max_level| (0..max_level).to_a }
    level_ranges.first.product(*level_ranges[1..]).each do |scheme|
      groups = Hash.new(0)
      rows.each { |row| groups[bf_key(row, fields, scheme, cat: cat, num: num)] += 1 }
      suppressed = groups.values.select { |count| count < k }.sum
      next if suppressed > max_suppressed

      per_row = scheme.each_with_index.sum do |level, index|
        max_levels[index].positive? ? level.to_f / max_levels[index] : 0.0
      end
      loss = (per_row * (rows.size - suppressed) + suppressed * denominator) /
             (rows.size * denominator.to_f)
      losses[scheme] = loss
    end
    losses
  end

  describe ".call" do
    context "with a tiny categorical table" do
      let(:rows) do
        [{city: "bj"}, {city: "bj"}, {city: "sh"}, {city: "gz"}]
      end
      let(:hierarchies) { {city: {"bj" => "cn", "sh" => "cn", "gz" => "cn"}} }

      it "picks the lowest-loss feasible scheme and reports per-row destinations" do
        result = described_class.call(
          rows,
          quasi_identifiers: %i[city],
          k: 2,
          max_suppression: 0.5,
          categorical_hierarchies: hierarchies
        )

        expect(result).to be_feasible
        expect(result).to be_proven_optimal
        expect(result.scheme).to eql(city: 0)
        expect(result.suppressed).to eql([2, 3])
        expect(result.assignments).to eql(
          [{city: "bj"}, {city: "bj"}, :suppressed, :suppressed]
        )
        expect(result.loss).to be_within(1e-9).of(0.5)
      end

      it "generalizes everything when suppression is not allowed" do
        result = described_class.call(
          rows,
          quasi_identifiers: %i[city],
          k: 2,
          max_suppression: 0.0,
          categorical_hierarchies: hierarchies
        )

        expect(result.scheme).to eql(city: 1)
        expect(result.suppressed).to be_empty
        expect(result.assignments).to all(eql(city: "cn"))
        expect(result.loss).to be_within(1e-9).of(1.0)
      end
    end

    context "with missing values forming a small class" do
      it "suppresses the missing-value class instead of distorting the scheme" do
        rows = [
          {city: "bj", age: 30},
          {city: "bj", age: 31},
          {city: "bj", age: 32},
          {city: nil, age: 40}
        ]
        result = described_class.call(
          rows,
          quasi_identifiers: %i[city age],
          k: 2,
          max_suppression: 0.5,
          categorical_hierarchies: {city: {"bj" => "cn"}},
          numeric_hierarchies: {age: [[0, 120]]}
        )

        expect(result).to be_feasible
        expect(result).to be_proven_optimal
        expect(result.scheme).to eql(city: 0, age: 1)
        expect(result.suppressed).to eql([3])
        expect(result.assignments[3]).to eql(:suppressed)
        expect(result.assignments[0..2]).to eql(
          Array.new(3, {city: "bj", age: "0-120"})
        )
      end

      it "keeps missing numerics as their own class at every level" do
        rows = [{age: 20}, {age: 21}, {age: nil}]
        result = described_class.call(
          rows,
          quasi_identifiers: %i[age],
          k: 2,
          max_suppression: 0.5,
          numeric_hierarchies: {age: [[0, 120]]}
        )

        expect(result.suppressed).to eql([2])
        expect(result.assignments[2]).to eql(:suppressed)
        expect(result.scheme).to eql(age: 1)
        expect(result.assignments[0..1]).to eql([{age: "0-120"}, {age: "0-120"}])
      end
    end

    context "when the evaluation budget runs out" do
      let(:rows) do
        [
          {a: "x", b: "p"},
          {a: "y", b: "p"},
          {a: "x", b: "q"},
          {a: "y", b: "q"}
        ]
      end
      let(:options) do
        {
          quasi_identifiers: %i[a b],
          k: 2,
          max_suppression: 0.0,
          categorical_hierarchies: {
            a: {"x" => "*", "y" => "*"},
            b: {"p" => "P", "q" => "P", "P" => "*"}
          }
        }
      end

      it "returns the best known scheme flagged as not proven optimal" do
        optimal = described_class.call(rows, **options)
        expect(optimal.scheme).to eql(a: 0, b: 1)
        expect(optimal).to be_proven_optimal

        budgeted = described_class.call(rows, **options, max_evaluations: 2)
        expect(budgeted).to be_feasible
        expect(budgeted).not_to be_proven_optimal
        expect(budgeted.scheme).to eql(a: 1, b: 0)
        expect(budgeted.loss).to be > optimal.loss
      end
    end

    context "when no feasible scheme exists" do
      it "reports infeasibility" do
        rows = [{city: "a"}, {city: "b"}, {city: "c"}, {city: "d"}]
        result = described_class.call(
          rows,
          quasi_identifiers: %i[city],
          k: 3,
          max_suppression: 0.0
        )

        expect(result).not_to be_feasible
        expect(result).not_to be_proven_optimal
        expect(result.assignments).to be_empty
      end
    end

    context "with an empty table" do
      it "returns a trivially feasible result" do
        result = described_class.call([], quasi_identifiers: %i[city], k: 2)

        expect(result).to be_feasible
        expect(result).to be_proven_optimal
        expect(result.loss).to eql(0.0)
        expect(result.assignments).to be_empty
      end
    end

    context "with sensitive attributes present" do
      it "never lets them influence grouping" do
        rows = [{city: "bj"}, {city: "bj"}, {city: "sh"}, {city: "gz"}]
        sensitive = %w[flu hiv cold diabetes]
        enriched = rows.map.with_index do |row, index|
          row.merge(diagnosis: sensitive[index], patient_id: "p#{index}")
        end
        options = {
          quasi_identifiers: %i[city],
          k: 2,
          max_suppression: 0.5,
          categorical_hierarchies: {city: {"bj" => "cn", "sh" => "cn", "gz" => "cn"}}
        }

        plain = described_class.call(rows, **options)
        with_sensitive = described_class.call(enriched, **options)

        expect(with_sensitive.scheme).to eql(plain.scheme)
        expect(with_sensitive.suppressed).to eql(plain.suppressed)
        expect(with_sensitive.loss).to eql(plain.loss)
      end
    end

    context "with globally consistent levels" do
      it "assigns identical labels to identical raw values across all rows" do
        rows = [
          {city: "bj", age: 25},
          {city: "sh", age: 27},
          {city: "bj", age: 25},
          {city: "sh", age: 29}
        ]
        result = described_class.call(
          rows,
          quasi_identifiers: %i[city age],
          k: 2,
          categorical_hierarchies: {city: {"bj" => "cn", "sh" => "cn"}},
          numeric_hierarchies: {age: [[0, 30, 120]]}
        )

        expect(result).to be_feasible
        expect(result.assignments[0]).to eql(result.assignments[2])
        expect(result.assignments[1]).to eql(result.assignments[3])
        result.assignments.each do |assignment|
          expect(assignment.keys).to eql(%i[city age])
        end
      end
    end

    context "optimality against exhaustive enumeration" do
      let(:cat) do
        {
          city: {
            "bj" => "cn", "sh" => "cn", "gz" => "cn", "sz" => "cn",
            "cn" => "*"
          }
        }
      end
      let(:num) { {age: [[0, 30, 60, 120], [0, 60, 120]]} }
      let(:fields) { %i[age city] }

      def check_optimality(rows, fields, cat, num, k, max_suppression)
        max_suppressed = (max_suppression * rows.size).floor
        result = described_class.call(
          rows,
          quasi_identifiers: fields,
          k: k,
          max_suppression: max_suppression,
          categorical_hierarchies: cat,
          numeric_hierarchies: num
        )
        losses = bf_enumerate(rows, fields, k, max_suppressed, cat: cat, num: num)
        best = losses.values.min

        if best.nil?
          expect(result).not_to be_feasible
        else
          expect(result).to be_feasible
          expect(result).to be_proven_optimal
          expect(result.loss).to be_within(1e-9).of(best)
          scheme_vector = fields.map { |field| result.scheme[field] }
          expect(losses[scheme_vector]).to be_within(1e-9).of(result.loss)

          kept = result.assignments.reject { |assignment| assignment == :suppressed }
          counts = Hash.new(0)
          kept.each { |assignment| counts[assignment] += 1 }
          expect(counts.values).to all(be >= k)
          expect(result.suppressed.size).to be <= max_suppressed
        end
      end

      it "matches the brute-force optimum on a hand-built table" do
        rows = [
          {age: 25, city: "bj"}, {age: 27, city: "bj"},
          {age: 31, city: "sh"}, {age: 33, city: "sh"},
          {age: 45, city: "gz"}, {age: 47, city: "gz"},
          {age: 52, city: "sz"}, {age: 54, city: "sz"},
          {age: 61, city: "bj"}, {age: 63, city: "sh"}
        ]
        check_optimality(rows, fields, cat, num, 2, 0.3)
        check_optimality(rows, fields, cat, num, 3, 0.4)
      end

      it "matches the brute-force optimum on generated tables with missing values" do
        rng = Random.new(765)
        cities = %w[bj sh gz sz]
        3.times do
          rows = Array.new(12) do
            {
              age: rng.rand < 0.1 ? nil : rng.rand(18..70),
              city: rng.rand < 0.1 ? nil : cities[rng.rand(cities.size)]
            }
          end
          check_optimality(rows, fields, cat, num, 2, 0.25)
          check_optimality(rows, fields, cat, num, 3, 0.33)
        end
      end
    end
  end
end
