# frozen_string_literal: true

module Dry
  module Transformer
    module Incremental
      UnsupportedTransformationError = Class.new(Error)
      InvalidEventError = Class.new(Error)
      DuplicateRowError = Class.new(Error)
      MissingRowError = Class.new(Error)
    end
  end
end
