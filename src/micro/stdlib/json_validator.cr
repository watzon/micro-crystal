require "json"

module Micro
  module Stdlib
    # Provides safe JSON parsing and validation utilities
    module JSONValidator
      # Result of JSON validation
      struct ValidationResult
        property valid : Bool
        property data : JSON::Any?
        property errors : Array(String)

        def initialize(@valid : Bool, @data : JSON::Any? = nil, @errors : Array(String) = [] of String)
        end

        def success?
          @valid
        end

        def failure?
          !@valid
        end
      end

      # Field validation rule
      struct FieldRule
        property required : Bool
        property type : String?
        property min_length : Int32?
        property max_length : Int32?
        property pattern : Regex?
        property min : Float64?
        property max : Float64?
        property enum_values : Array(JSON::Any)?
        property custom : Proc(JSON::Any, Bool)?

        def initialize(
          @required = false,
          @type = nil,
          @min_length = nil,
          @max_length = nil,
          @pattern = nil,
          @min = nil,
          @max = nil,
          @enum_values = nil,
          @custom = nil,
        )
        end
      end

      # Schema definition for JSON validation
      class Schema
        @fields : Hash(String, FieldRule)
        @allow_extra_fields : Bool

        def initialize(@allow_extra_fields = false)
          @fields = {} of String => FieldRule
        end

        # Add a field rule to the schema
        def field(name : String, **options) : self
          rule = FieldRule.new(
            required: options[:required]? || false,
            type: options[:type]?.try(&.to_s),
            min_length: options[:min_length]?,
            max_length: options[:max_length]?,
            pattern: options[:pattern]?,
            min: options[:min]?.try(&.to_f64),
            max: options[:max]?.try(&.to_f64),
            enum_values: options[:enum]?,
            custom: options[:custom]?
          )
          @fields[name] = rule
          self
        end

        # Validate JSON against the schema
        def validate(json : JSON::Any) : ValidationResult
          errors = [] of String

          unless json.as_h?
            errors << "Expected JSON object at root level"
            return ValidationResult.new(false, nil, errors)
          end

          obj = json.as_h

          # Check required fields
          @fields.each do |field_name, rule|
            if rule.required && !obj.has_key?(field_name)
              errors << "Required field '#{field_name}' is missing"
            end
          end

          # Validate each field
          obj.each do |key, value|
            if rule = @fields[key]?
              validate_field(key, value, rule, errors)
            elsif !@allow_extra_fields
              errors << "Unexpected field '#{key}'"
            end
          end

          if errors.empty?
            ValidationResult.new(true, json)
          else
            ValidationResult.new(false, json, errors)
          end
        end

        # Validates a single field against its validation rules.
        # Checks type, format, range, and custom validators.
        # Adds any validation errors to the errors array.
        private def validate_field(name : String, value : JSON::Any, rule : FieldRule, errors : Array(String))
          # Type validation
          if expected_type = rule.type
            actual_type = json_type_name(value)
            if expected_type != actual_type && !(expected_type == "number" && actual_type.in?(["int", "float"]))
              errors << "Field '#{name}' expected type '#{expected_type}', got '#{actual_type}'"
              return
            end
          end

          # String validations
          if str = value.as_s?
            if min_len = rule.min_length
              if str.size < min_len
                errors << "Field '#{name}' must be at least #{min_len} characters"
              end
            end

            if max_len = rule.max_length
              if str.size > max_len
                errors << "Field '#{name}' must be at most #{max_len} characters"
              end
            end

            if pattern = rule.pattern
              unless str.matches?(pattern)
                errors << "Field '#{name}' does not match required pattern"
              end
            end
          end

          # Number validations
          if num = (value.as_i? || value.as_f?)
            num_val = num.to_f64

            if min = rule.min
              if num_val < min
                errors << "Field '#{name}' must be at least #{min}"
              end
            end

            if max = rule.max
              if num_val > max
                errors << "Field '#{name}' must be at most #{max}"
              end
            end
          end

          # Enum validation
          if enum_values = rule.enum_values
            unless enum_values.includes?(value)
              errors << "Field '#{name}' must be one of: #{enum_values.map(&.to_s).join(", ")}"
            end
          end

          # Custom validation
          if custom = rule.custom
            unless custom.call(value)
              errors << "Field '#{name}' failed custom validation"
            end
          end
        end

        # Returns a human-readable type name for a JSON value.
        # Used in error messages for better clarity.
        private def json_type_name(value : JSON::Any) : String
          case value.raw
          when String
            "string"
          when Int64
            "int"
          when Float64
            "float"
          when Bool
            "bool"
          when Array
            "array"
          when Hash
            "object"
          when Nil
            "null"
          else
            "unknown"
          end
        end
      end

      # Safe JSON parsing with error handling
      def self.parse(input : String | IO) : ValidationResult
        data = JSON.parse(input)
        ValidationResult.new(true, data)
      rescue ex : JSON::ParseException
        errors = ["JSON parse error at line #{ex.line_number}, column #{ex.column_number}: #{ex.message}"]
        ValidationResult.new(false, nil, errors)
      rescue ex
        errors = ["Unexpected error during JSON parsing: #{ex.message}"]
        ValidationResult.new(false, nil, errors)
      end

      # Parse and validate in one step
      def self.parse_and_validate(input : String | IO, schema : Schema) : ValidationResult
        parse_result = parse(input)
        return parse_result unless parse_result.success?

        if data = parse_result.data
          schema.validate(data)
        else
          ValidationResult.new(false, nil, ["No data to validate"])
        end
      end

      # Create a new schema builder
      def self.schema(allow_extra_fields = false, &) : Schema
        schema = Schema.new(allow_extra_fields)
        with schema yield
        schema
      end

      # Type-safe parsing into specific types
      def self.parse_as(type : T.class, input : String | IO) : T? forall T
        result = parse(input)
        return nil unless result.success?

        if data = result.data
          begin
            T.from_json(data.to_json)
          rescue
            nil
          end
        else
          nil
        end
      end

      # Parse with default value
      def self.parse_with_default(input : String | IO, default : JSON::Any) : JSON::Any
        result = parse(input)
        if result.success? && (data = result.data)
          data
        else
          default
        end
      end
    end
  end
end
