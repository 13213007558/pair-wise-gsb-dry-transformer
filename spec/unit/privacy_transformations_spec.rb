# frozen_string_literal: true

RSpec.describe Dry::Transformer::PrivacyTransformations do
  describe ".k_anonymize" do
    # Balanced tree of 4 leaves. Root-to-leaf paths have 2 edges, so the
    # column offers generalization levels 0 (leaf) .. 2 (root):
    #
    #   level 2            World
    #   level 1        /           \
    #               North          South
    #   level 0     /   \          /   \
    #              A     B        C     D
    #
    # Loss: leaf 0, continent 1/3, world 1.
    let(:city_tree) do
      {
        "World" => {
          "North" => {"A" => nil, "B" => nil},
          "South" => {"C" => nil, "D" => nil}
        }
      }
    end

    let(:city_spec) { {key: :city, type: :categorical, tree: city_tree} }

    # Two explicit numeric levels (half-open bins) over a finest-level span
    # of 30: level 1 decades (width 10), level 2 wider groups.
    let(:age_ranges) { [[20...30, 30...40, 40...50], [20...40, 40...50]] }
    let(:age_spec) { {key: :age, type: :numeric, ranges: age_ranges} }

    def call(rows, **options)
      described_class[:k_anonymize].call(rows, **options)
    end

    context "single categorical quasi-identifier" do
      let(:rows) do
        [
          {city: "A", condition: "flu"},
          {city: "B", condition: "cold"},
          {city: "C", condition: "flu"},
          {city: "D", condition: "cold"}
        ]
      end

      it "picks the least lossy feasible level and proves it optimal" do
        result = call(rows, k: 2, quasi_identifiers: [city_spec])

        expect(result).to be_feasible
        expect(result).to be_proven_optimal
        expect(result.levels).to eql(city: 1)
        expect(result.suppressed_count).to be(0)
        expect(result.loss).to be_within(1e-12).of(1.0 / 3)
        expect(result.total_schemes).to be(3)
        # The root level is pruned once the cheaper continent is known.
        expect(result.evaluations).to be(2)
      end

      it "suppresses small classes when that loses less than generalizing" do
        table = rows + [
          {city: "A", condition: "headache"},
          {city: "B", condition: "fever"},
          {city: "C", condition: "fever"}
        ]

        result = call(table, k: 2, quasi_identifiers: [city_spec],
                             max_suppression: 0.5)

        expect(result.levels).to eql(city: 0)
        expect(result.suppressed_rows).to eql([{city: "D", condition: "cold"}])
        expect(result.suppressed_count).to be(1)
        expect(result.suppression_rate).to be_within(1e-12).of(1.0 / 7)
        expect(result.loss).to be_within(1e-12).of(1.0 / 7)
        expect(result.rows.size).to be(6)
      end

      it "generalizes instead of suppressing once the budget is exceeded" do
        table = rows + [
          {city: "A", condition: "headache"},
          {city: "B", condition: "fever"},
          {city: "C", condition: "fever"}
        ]

        result = call(table, k: 2, quasi_identifiers: [city_spec],
                             max_suppression: 0.1)

        expect(result.levels).to eql(city: 1)
        expect(result.suppressed_count).to be(0)
        expect(result.loss).to be_within(1e-12).of(1.0 / 3)
      end

      it "reports infeasibility rather than raising when nothing fits" do
        # k exceeds the table size, so even the root class stays too small.
        table = rows.first(3)

        result = call(table, k: 4, quasi_identifiers: [city_spec])

        expect(result).not_to be_feasible
        expect(result).to be_proven_optimal
        expect(result.levels).to be_nil
        expect(result.rows).to eql([])
        expect(result.suppressed_rows).to eql(table)
        expect(result.suppression_rate).to be_within(1e-12).of(1.0)
        expect(result.loss).to be(1.0)
      end
    end

    context "mixed quasi-identifiers" do
      let(:rows) do
        [
          {city: "A", age: 20, condition: "flu"},
          {city: "B", age: 22, condition: "cold"},
          {city: "C", age: 41, condition: "flu"},
          {city: "D", age: 43, condition: "cold"}
        ]
      end

      it "keeps sensitive columns untouched and out of grouping" do
        result = call(rows, k: 2, quasi_identifiers: [city_spec, age_spec])

        expect(result.levels).to eql(city: 1, age: 1)
        expect(result.rows).to eql(
          [
            {city: "North", age: 20...30, condition: "flu"},
            {city: "North", age: 20...30, condition: "cold"},
            {city: "South", age: 40...50, condition: "flu"},
            {city: "South", age: 40...50, condition: "cold"}
          ]
        )
        expect(result.destinations).to all(
          include(released: true, group_size: 2)
        )
      end

      it "averages per-column losses for released rows" do
        result = call(rows, k: 2, quasi_identifiers: [city_spec, age_spec])

        city_loss = 1.0 / 3
        age_loss = 10.0 / 30
        expect(result.loss).to be_within(1e-12).of((city_loss + age_loss) / 2)
        expect(result.destinations.first[:loss])
          .to be_within(1e-12).of((city_loss + age_loss) / 2)
      end

      it "uses interval width over the finest-level span for numeric loss" do
        table = [
          {age: 20, condition: "flu"},
          {age: 22, condition: "cold"},
          {age: 41, condition: "flu"},
          {age: 43, condition: "cold"}
        ]

        result = call(table, k: 2, quasi_identifiers: [age_spec])

        expect(result.levels).to eql(age: 1)
        expect(result.loss).to be_within(1e-12).of(1.0 / 3)
      end

      it "applies one global level per column" do
        table = rows + [{city: "A", age: 25, condition: "fever"}]

        result = call(table, k: 2, quasi_identifiers: [city_spec, age_spec],
                             max_suppression: 0.5)

        ages = result.rows.map { |row| row[:age] }.uniq
        expect(ages).to all(be_a(Range))
      end
    end

    context "missing quasi-identifier values" do
      let(:rows) do
        [
          {city: "A", condition: "flu"},
          {city: "A", condition: "cold"},
          {city: "B", condition: "flu"},
          {city: nil, condition: "unknown"},
          {city: "B", condition: "cold"},
          {city: nil, condition: "unknown"}
        ]
      end

      it "keeps missing values in a class generalization cannot merge" do
        result = call(rows, k: 3, quasi_identifiers: [city_spec],
                             max_suppression: 0.34)

        expect(result.levels).to eql(city: 1)
        expect(result.suppressed_count).to be(2)
        expect(result.suppression_rate).to be_within(1e-12).of(2.0 / 6)
        expect(result.rows).to eql(
          [
            {city: "North", condition: "flu"},
            {city: "North", condition: "cold"},
            {city: "North", condition: "flu"},
            {city: "North", condition: "cold"}
          ]
        )
        expect(result.suppressed_rows).to eql(
          [
            {city: nil, condition: "unknown"},
            {city: nil, condition: "unknown"}
          ]
        )
        suppressed = result.destinations.reject { |d| d[:released] }
        expect(suppressed).to all(
          include(group: {city: nil}, group_size: 2, loss: 1.0)
        )
      end

      it "is infeasible when the missing class cannot be generalized to k" do
        table = rows.first(5)

        result = call(table, k: 3, quasi_identifiers: [city_spec],
                             max_suppression: 0.1)

        expect(result).not_to be_feasible
        expect(result).to be_proven_optimal
      end
    end

    context "edge cases" do
      it "releases an empty table as feasible with zero loss" do
        result = call([], k: 2, quasi_identifiers: [city_spec])

        expect(result).to be_feasible
        expect(result).to be_proven_optimal
        expect(result.rows).to eql([])
        expect(result.suppressed_count).to be(0)
        expect(result.loss).to be(0.0)
      end

      it "keeps numeric missing values in their own non-generalized class" do
        table = [
          {age: 20, condition: "flu"},
          {age: 21, condition: "cold"},
          {age: nil, condition: "unknown"}
        ]

        result = call(table, k: 2, quasi_identifiers: [age_spec],
                             max_suppression: 0.34)

        expect(result.levels).to eql(age: 1)
        expect(result.suppressed_rows).to eql([{age: nil, condition: "unknown"}])
        expect(result.rows.map { |row| row[:age] }).to all(be_a(Range))
      end

      it "rejects a non-array table" do
        expect { call({a: 1}, k: 2, quasi_identifiers: [city_spec]) }
          .to raise_error(ArgumentError, /array of tuples/)
      end
    end

    context "evaluation budget" do
      # Columns are searched in given order: putting age first means scheme
      # (age: 1, city: 0) is the first feasible combination.
      let(:budget_rows) do
        [
          {city: "A", age: 20},
          {city: "B", age: 22},
          {city: "C", age: 41},
          {city: "D", age: 43}
        ]
      end

      it "returns the best scheme found but leaves optimality unproven" do
        result = call(budget_rows, k: 2,
                                   quasi_identifiers: [age_spec, city_spec],
                                   budget: 5)

        expect(result).to be_feasible
        expect(result).not_to be_proven_optimal
        expect(result.evaluations).to be(5)
      end

      it "reports infeasibility as unproven when the budget runs out first" do
        result = call(budget_rows, k: 2,
                                   quasi_identifiers: [age_spec, city_spec],
                                   budget: 1)

        expect(result).not_to be_feasible
        expect(result).not_to be_proven_optimal
        expect(result.evaluations).to be(1)
      end

      it "proves optimality after evaluating the full lattice" do
        result = call(budget_rows, k: 2,
                                   quasi_identifiers: [age_spec, city_spec],
                                   budget: 100)

        expect(result).to be_proven_optimal
        expect(result.total_schemes).to be(9)
      end
    end

    context "validation" do
      let(:rows) { [{city: "A"}, {city: "B"}] }

      it "rejects k below 1" do
        expect { call(rows, k: 0, quasi_identifiers: [city_spec]) }
          .to raise_error(ArgumentError, /positive integer/)
      end

      it "rejects suppression budgets outside [0, 1]" do
        expect {
          call(rows, k: 2, quasi_identifiers: [city_spec], max_suppression: 2)
        }.to raise_error(ArgumentError, /max_suppression/)
      end

      it "rejects values absent from the categorical tree" do
        expect {
          call([{city: "Z"}, {city: "Z"}], k: 2,
               quasi_identifiers: [city_spec])
        }.to raise_error(ArgumentError, /not present in tree/)
      end

      it "rejects duplicate quasi-identifier columns" do
        expect {
          call(rows, k: 2, quasi_identifiers: [city_spec, city_spec])
        }.to raise_error(ArgumentError, /unique/)
      end

      it "rejects numeric values outside the declared domain" do
        expect {
          call([{age: 5}, {age: 55}], k: 2, quasi_identifiers: [age_spec])
        }.to raise_error(ArgumentError, /outside numeric domain/)
      end

      it "rejects overlapping numeric intervals" do
        bad_spec = {key: :age, type: :numeric, ranges: [[0..10, 10..19]]}
        expect {
          call([{age: 5}, {age: 15}], k: 2, quasi_identifiers: [bad_spec])
        }.to raise_error(ArgumentError, /overlap/)
      end

      it "rejects unbalanced categorical trees" do
        bad_tree = {"Root" => {"A" => nil, "Branch" => {"B" => nil}}}
        bad_spec = {key: :city, type: :categorical, tree: bad_tree}
        expect {
          call(rows, k: 2, quasi_identifiers: [bad_spec])
        }.to raise_error(ArgumentError, /not balanced/)
      end
    end
  end
end
