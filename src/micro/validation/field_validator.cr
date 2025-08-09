# Field-based validator using @[Micro::Field] annotations
require "json"

module Micro::Validators
  # Mixin to automatically generate validators for types with Field annotations
  module AutoValidate
    macro included
      def validate : ::Micro::Validators::ValidationResult
        result = ::Micro::Validators::ValidationResult.new

        \{% for ivar in @type.instance_vars %}
          \{%
             field_ann = ivar.annotation(::Micro::Field)
          %}
          \{% if field_ann %}
            \{%
               validate_rules = field_ann[:validate]
               field_name = ivar.name.stringify
               field_type = ivar.type
               is_nilable = field_type.stringify.includes?("Nil")
            %}
            # Validate \{{field_name}}
            field_value = @\{{ivar.name}}

            \{% if validate_rules %}
              \{%  # Required validation
if validate_rules[:required] %}
                if field_value.nil?
                  result.add_error(\{{field_name}}, "required", "Field is required")
                \{% if !is_nilable %}
                elsif field_value.responds_to?(:empty?) && field_value.empty?
                  result.add_error(\{{field_name}}, "required", "Field cannot be empty")
                \{% end %}
                end
              \{% end %}

              unless field_value.nil?
                \{%  # String validations
if validate_rules[:min_length] %}
                  if field_value.responds_to?(:size) && field_value.size < \{{validate_rules[:min_length]}}
                    result.add_error(\{{field_name}}, "min_length", "Must be at least \{{validate_rules[:min_length]}} characters")
                  end
                \{% end %}

                \{% if validate_rules[:max_length] %}
                  if field_value.responds_to?(:size) && field_value.size > \{{validate_rules[:max_length]}}
                    result.add_error(\{{field_name}}, "max_length", "Must be at most \{{validate_rules[:max_length]}} characters")
                  end
                \{% end %}

                \{%  # Numeric validations
if validate_rules[:min_value] %}
                  if field_value.responds_to?(:<) && field_value < \{{validate_rules[:min_value]}}
                    result.add_error(\{{field_name}}, "min_value", "Must be at least \{{validate_rules[:min_value]}}")
                  end
                \{% end %}

                \{% if validate_rules[:max_value] %}
                  if field_value.responds_to?(:>) && field_value > \{{validate_rules[:max_value]}}
                    result.add_error(\{{field_name}}, "max_value", "Must be at most \{{validate_rules[:max_value]}}")
                  end
                \{% end %}

                \{%  # Pattern matching
if validate_rules[:matches] %}
                  unless field_value.to_s.matches?(\{{validate_rules[:matches]}})
                    result.add_error(\{{field_name}}, "pattern", "Does not match required pattern")
                  end
                \{% end %}

                \{%  # Enum validation
if validate_rules[:enum] %}
                  allowed_values = \{{validate_rules[:enum]}}
                  unless allowed_values.includes?(field_value)
                    result.add_error(\{{field_name}}, "enum", "Must be one of: #{allowed_values.join(", ")}")
                  end
                \{% end %}

                \{%  # Custom validator
if validate_rules[:custom] %}
                  if responds_to?(\{{validate_rules[:custom].symbolize}})
                    custom_result = self.\{{validate_rules[:custom].id}}(field_value)
                    if custom_result.is_a?(String)
                      result.add_error(\{{field_name}}, "custom", custom_result)
                    elsif custom_result == false
                      result.add_error(\{{field_name}}, "custom", "Failed custom validation")
                    end
                  end
                \{% end %}
              end
            \{% end %}
          \{% end %}
        \{% end %}

        result
      end

      # Include the Validatable methods
      include ::Micro::Validators::Validatable
    end
  end
end
