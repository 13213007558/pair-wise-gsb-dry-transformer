# frozen_string_literal: true

module Dry
  module Transformer
    # Incremental evaluation of declarative row transformations.
    #
    # An {Incremental::Session} maintains the result of a small declarative
    # pipeline (map / filter / rename / group with retractable sum & count
    # aggregations) over a collection of rows that carry stable row ids.
    #
    # Instead of re-running the whole pipeline whenever the input changes,
    # the session consumes add / remove / update events and returns a delta
    # describing how the output changed relative to the previous result.
    #
    # Rows are tracked by their stable id, never by their content, so two
    # rows with identical content but different ids are always kept apart.
    #
    # Only transformations with derivable incremental rules are supported.
    # Arbitrary collection-level procs are rejected, and non-retractable
    # aggregations (anything but sum/count) are rejected unless the session
    # is configured with +on_unsupported: :recompute+, in which case the
    # session explicitly degrades to re-executing the whole pipeline and
    # diffing the previous and next results.
    #
    # @example
    #   session = Dry::Transformer::Incremental::Session.new(id: :id) do |t|
    #     t.rename user_name: :name
    #     t.filter { |row| row[:active] }
    #     t.group :city do |g|
    #       g.sum :amount
    #       g.count
    #     end
    #   end
    #
    #   session.apply([{type: :add, row: {id: 1, user_name: "jane", active: true, city: "NYC", amount: 10}}])
    #   # => #<Dry::Transformer::Incremental::GroupDelta added={"NYC"=>{:sum_amount=>10, :count=>1}} ...>
    #
    # @api public
    module Incremental
    end
  end
end
