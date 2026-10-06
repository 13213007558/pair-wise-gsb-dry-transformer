# frozen_string_literal: true

RSpec.describe Dry::Transformer::ArrayTransformations do
  describe ".filter_array" do
    it "filters with a declarative equality predicate" do
      fn = described_class[:filter_array, active: true]

      expect(fn.call([
        {active: true, name: "Jane"},
        {active: false, name: "John"}
      ])).to eql([{active: true, name: "Jane"}])
    end

    it "supports the filter alias" do
      fn = described_class[:filter, :active]

      expect(fn.call([{active: true}, {active: nil}])).to eql([{active: true}])
    end
  end

  describe ".aggregate" do
    it "groups count and retractable sums" do
      fn = described_class[:aggregate, {
        group_by: :category,
        count: :count,
        sum: {total: :amount}
      }]

      input = [
        {category: "books", amount: 1},
        {category: "books", amount: nil},
        {category: "music", amount: 4}
      ]

      expect(fn.call(input)).to eql([
        {category: "books", count: 2, total: 1},
        {category: "music", count: 1, total: 4}
      ])
    end

    it "supports one global aggregate" do
      fn = described_class[:aggregate, count: true, sum: :amount]

      expect(fn.call([{amount: 1}, {amount: 2}])).to eql([count: 2, amount: 3])
    end
  end
end
