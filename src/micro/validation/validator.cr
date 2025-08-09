# Automatic validation from @[Micro::Schema] annotations
require "json"

module Micro::Validators
  # Base validation error
  class ValidationError < Exception
    getter field : String
    getter value : JSON::Any?
    getter constraint : String

    def initialize(@field : String, @value : JSON::Any?, @constraint : String, message : String? = nil)
      super(message || "Validation failed for field '#{@field}': #{@constraint}")
    end
  end

  # Collection of validation errors
  class ValidationErrors < Exception
    getter errors : Array(ValidationError)

    def initialize(@errors : Array(ValidationError))
      super("Validation failed with #{@errors.size} error(s)")
    end

    def to_json(json : JSON::Builder)
      json.object do
        json.field "errors" do
          json.array do
            @errors.each do |error|
              json.object do
                json.field "field", error.field
                json.field "constraint", error.constraint
                json.field "message", error.message
                json.field "value", error.value if error.value
              end
            end
          end
        end
      end
    end
  end

  # Validation result
  struct ValidationResult
    getter valid : Bool
    getter errors : Array(ValidationError)

    def initialize(@valid : Bool, @errors : Array(ValidationError) = [] of ValidationError)
    end

    def self.success
      new(true)
    end

    def self.failure(errors : Array(ValidationError))
      new(false, errors)
    end
  end

  # Validator module that generates validation at compile time
  module Validator
    # Macro to generate validation method for a type
    macro generate_validator(type)
      {%
        schema_ann = type.resolve.annotation(::Micro::Schema)

        # Get validation rules from annotations
        required_fields = nil

        if schema_ann
          required_fields = schema_ann[:required]
        end
      %}

      {% if schema_ann %}
        # Generate validator for {{type.stringify}}
        def self.validate_{{type.stringify.underscore.gsub(/::/, "_").id}}(instance : {{type}}) : ValidationResult
          errors = [] of ValidationError

          {% # Get public methods (properties)

 type_methods = type.resolve.methods.select { |m|
   m.name != "initialize" &&
     m.args.empty? &&
     !m.name.ends_with?("=") &&
     !m.name.starts_with?("_") &&
     m.visibility == :public
 } %}

          {% for method in type_methods %}
            {%
              prop_name = method.name.stringify
              prop_type = method.return_type
              type_str = prop_type.stringify if prop_type
              is_nilable = type_str && type_str.includes?(" | ::Nil")
              clean_type_str = type_str.gsub(/ \| ::Nil/, "") if type_str
            %}

            # Validate {{prop_name}}
            value = instance.{{method.name.id}}

            {% if required_fields && required_fields.includes?(prop_name) %}
              # Required field check
              if value.nil?
                errors << ValidationError.new(
                  field: {{prop_name}},
                  value: nil,
                  constraint: "required",
                  message: "Field '#{{{prop_name}}}' is required"
                )
              end
            {% end %}

            {% if !is_nilable || (required_fields && required_fields.includes?(prop_name)) %}
              unless value.nil?
                {% if clean_type_str == "String" %}
                  # String validations
                  {% if prop_name == "email" %}
                    # Email validation
                    unless value.matches?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
                      errors << ValidationError.new(
                        field: {{prop_name}},
                        value: JSON::Any.new(value),
                        constraint: "email",
                        message: "Field '#{{{prop_name}}}' must be a valid email address"
                      )
                    end
                  {% elsif prop_name == "password" %}
                    # Password validation
                    if value.size < 8
                      errors << ValidationError.new(
                        field: {{prop_name}},
                        value: nil, # Don't include password in error
                        constraint: "min_length",
                        message: "Password must be at least 8 characters"
                      )
                    end
                  {% elsif prop_name.includes?("url") || prop_name.includes?("uri") %}
                    # URL validation
                    begin
                      URI.parse(value)
                    rescue
                      errors << ValidationError.new(
                        field: {{prop_name}},
                        value: JSON::Any.new(value),
                        constraint: "uri",
                        message: "Field '#{{{prop_name}}}' must be a valid URI"
                      )
                    end
                  {% elsif prop_name.includes?("_id") || prop_name == "id" %}
                    # UUID validation
                    unless value.matches?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
                      errors << ValidationError.new(
                        field: {{prop_name}},
                        value: JSON::Any.new(value),
                        constraint: "uuid",
                        message: "Field '#{{{prop_name}}}' must be a valid UUID"
                      )
                    end
                  {% elsif prop_name.includes?("_at") %}
                    # DateTime validation
                    begin
                      Time::Format::ISO_8601_DATE_TIME.parse(value)
                    rescue
                      errors << ValidationError.new(
                        field: {{prop_name}},
                        value: JSON::Any.new(value),
                        constraint: "date-time",
                        message: "Field '#{{{prop_name}}}' must be a valid ISO 8601 date-time"
                      )
                    end
                  {% end %}

                  # Check for empty strings if not allowed
                  {% unless is_nilable %}
                    if value.empty?
                      errors << ValidationError.new(
                        field: {{prop_name}},
                        value: JSON::Any.new(value),
                        constraint: "not_empty",
                        message: "Field '#{{{prop_name}}}' cannot be empty"
                      )
                    end
                  {% end %}

                {% elsif clean_type_str == "Int32" || clean_type_str == "Int64" %}
                  # Integer validations
                  {% if prop_name.includes?("age") %}
                    if value < 0 || value > 150
                      errors << ValidationError.new(
                        field: {{prop_name}},
                        value: JSON::Any.new(value.to_i64),
                        constraint: "range",
                        message: "Field '#{{{prop_name}}}' must be between 0 and 150"
                      )
                    end
                  {% elsif prop_name.includes?("stock") || prop_name.includes?("quantity") %}
                    if value < 0
                      errors << ValidationError.new(
                        field: {{prop_name}},
                        value: JSON::Any.new(value.to_i64),
                        constraint: "min",
                        message: "Field '#{{{prop_name}}}' cannot be negative"
                      )
                    end
                  {% end %}

                {% elsif clean_type_str == "Float32" || clean_type_str == "Float64" %}
                  # Float validations
                  {% if prop_name.includes?("price") || prop_name.includes?("cost") || prop_name.includes?("amount") %}
                    if value < 0
                      errors << ValidationError.new(
                        field: {{prop_name}},
                        value: JSON::Any.new(value),
                        constraint: "min",
                        message: "Field '#{{{prop_name}}}' cannot be negative"
                      )
                    end
                  {% elsif prop_name.includes?("percentage") || prop_name.includes?("rate") %}
                    if value < 0 || value > 100
                      errors << ValidationError.new(
                        field: {{prop_name}},
                        value: JSON::Any.new(value),
                        constraint: "range",
                        message: "Field '#{{{prop_name}}}' must be between 0 and 100"
                      )
                    end
                  {% end %}

                {% elsif clean_type_str && clean_type_str.starts_with?("Array(") %}
                  # Array validations
                  if value.responds_to?(:empty?) && value.empty?
                    {% unless is_nilable %}
                      errors << ValidationError.new(
                        field: {{prop_name}},
                        value: JSON::Any.new([] of JSON::Any),
                        constraint: "not_empty",
                        message: "Field '#{{{prop_name}}}' cannot be empty"
                      )
                    {% end %}
                  end
                {% end %}
              end
            {% end %}
          {% end %}


          if errors.empty?
            ValidationResult.success
          else
            ValidationResult.failure(errors)
          end
        end

        # Generate validate! method that raises on failure
        def self.validate_{{type.stringify.underscore.gsub(/::/, "_").id}}!(instance : {{type}}) : Nil
          result = validate_{{type.stringify.underscore.gsub(/::/, "_").id}}(instance)
          unless result.valid
            raise ValidationErrors.new(result.errors)
          end
        end
      {% else %}
        # No validation for types without Schema or Validation annotations
        def self.validate_{{type.stringify.underscore.gsub(/::/, "_").id}}(instance : {{type}}) : ValidationResult
          ValidationResult.success
        end

        def self.validate_{{type.stringify.underscore.gsub(/::/, "_").id}}!(instance : {{type}}) : Nil
          # No-op for types without validation
        end
      {% end %}
    end

    # Generic validate method that works with any type
    macro validate(instance)
      {% type_name = instance.class.name.underscore.gsub(/::/, "_") %}
      Micro::Validators::Validator.validate_{{type_name.id}}({{instance}})
    end

    # Generic validate! method that works with any type
    macro validate!(instance)
      {% type_name = instance.class.name.underscore.gsub(/::/, "_") %}
      Micro::Validators::Validator.validate_{{type_name.id}}!({{instance}})
    end
  end

  # Mixin to add validation to a class
  module Validatable
    macro included
      # Generate the validator for this type
      ::Micro::Validators::Validator.generate_validator(\{{@type}})

      # Add instance validation methods
      def validate : ::Micro::Validators::ValidationResult
        \{% type_name = @type.stringify.underscore.gsub(/::/, "_") %}
        ::Micro::Validators::Validator.validate_\{{type_name.id}}(self)
      end

      def validate! : Nil
        \{% type_name = @type.stringify.underscore.gsub(/::/, "_") %}
        ::Micro::Validators::Validator.validate_\{{type_name.id}}!(self)
      end

      def valid? : Bool
        validate.valid
      end
    end
  end
end
