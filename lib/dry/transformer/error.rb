# frozen_string_literal: true

module Dry
  module Transformer
    Error = Class.new(StandardError)
    FunctionAlreadyRegisteredError = Class.new(Error)

    # Raised when a transformation cannot be maintained incrementally and the
    # session is not configured to fall back to full recomputation
    UnsupportedTransformError = Class.new(Error)

    # Raised when an incremental session receives a malformed or inconsistent
    # event (duplicate id, unknown id, missing id key, ...)
    InvalidEventError = Class.new(Error)

    class FunctionNotFoundError < Error
      def initialize(function, source = nil)
        if source
          super "No registered function #{source}[:#{function}]"
        else
          super "No globally registered function for #{function}"
        end
      end
    end
  end
end
