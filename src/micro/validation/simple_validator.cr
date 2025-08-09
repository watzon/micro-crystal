# Simple validator that actually works
require "json"

module Micro::Validators
  class ValidationError < Exception
    getter field : String
    getter constraint : String

    def initialize(@field : String, @constraint : String, message : String? = nil)
      super(message || "Validation failed for field '#{@field}': #{@constraint}")
    end
  end

  class ValidationResult
    getter errors : Array(ValidationError)

    def initialize(@errors = [] of ValidationError)
    end

    def valid?
      @errors.empty?
    end

    def add_error(field : String, constraint : String, message : String? = nil)
      @errors << ValidationError.new(field, constraint, message)
    end
  end

  # Base validator class that types can extend
  abstract class BaseValidator
    abstract def validate(instance) : ValidationResult
  end

  # Mixin that adds validation methods to a type
  module Validatable
    abstract def validate : ValidationResult

    def valid? : Bool
      validate.valid?
    end

    def validate!
      result = validate
      unless result.valid?
        raise ValidationError.new(
          result.errors.first.field,
          result.errors.first.constraint,
          "Validation failed with #{result.errors.size} error(s)"
        )
      end
    end
  end
end
