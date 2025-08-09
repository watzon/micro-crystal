# Schema extractor for automatic OpenAPI schema generation from annotations
require "json"

module Micro::Gateway
  # Extracts OpenAPI schemas from types annotated with @[Micro::Schema]
  module SchemaExtractor
    # Macro to generate schema extraction at compile time
    macro extract_schema(type)
      {% # Get the Schema annotation if present

 schema_ann = type.resolve.annotation(::Micro::Schema) %}

      {% if schema_ann %}
        {%
          type_name = type.resolve.name.stringify
          description = schema_ann[:description]
          example = schema_ann[:example]
          required_fields = schema_ann[:required]
        %}

        # Generate schema for {{type_name}}
        begin
          schema_hash = {} of String => JSON::Any
          schema_hash["type"] = JSON::Any.new("object")

          {% if description %}
            schema_hash["description"] = JSON::Any.new({{description}})
          {% end %}

          {% if example %}
            schema_hash["example"] = JSON::Any.from_json({{example}})
          {% end %}

          # Extract properties from the type
          properties = {} of String => JSON::Any

          {% # For structs/classes with JSON::Serializable, we need to inspect methods
# that correspond to properties (getters)

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
            %}
            # Add property {{prop_name}} of type {{prop_type}}
            prop_schema = {} of String => JSON::Any

            {%
              type_str = prop_type.stringify
              # Handle nilable types (e.g., "String | ::Nil" -> "String?")
              is_nilable = type_str.includes?(" | ::Nil")
              clean_type_str = type_str.gsub(/ \| ::Nil/, "")
            %}
            {% if clean_type_str == "String" %}
              prop_schema["type"] = JSON::Any.new("string")
              {% if prop_name == "email" %}
                prop_schema["format"] = JSON::Any.new("email")
              {% elsif prop_name == "password" %}
                prop_schema["format"] = JSON::Any.new("password")
              {% elsif prop_name.includes?("_id") || prop_name == "id" %}
                prop_schema["format"] = JSON::Any.new("uuid")
              {% elsif prop_name.includes?("_at") %}
                prop_schema["format"] = JSON::Any.new("date-time")
              {% elsif prop_name.includes?("url") || prop_name.includes?("uri") %}
                prop_schema["format"] = JSON::Any.new("uri")
              {% end %}
            {% elsif clean_type_str == "Int32" %}
              prop_schema["type"] = JSON::Any.new("integer")
              prop_schema["format"] = JSON::Any.new("int32")
            {% elsif clean_type_str == "Int64" %}
              prop_schema["type"] = JSON::Any.new("integer")
              prop_schema["format"] = JSON::Any.new("int64")
            {% elsif clean_type_str == "Float32" %}
              prop_schema["type"] = JSON::Any.new("number")
              prop_schema["format"] = JSON::Any.new("float")
            {% elsif clean_type_str == "Float64" %}
              prop_schema["type"] = JSON::Any.new("number")
              prop_schema["format"] = JSON::Any.new("double")
            {% elsif clean_type_str == "Bool" %}
              prop_schema["type"] = JSON::Any.new("boolean")
            {% elsif clean_type_str.starts_with?("Array(") %}
              prop_schema["type"] = JSON::Any.new("array")
              # Extract inner type from Array(T)
              {% # Parse "Array(String)" -> "String"

 inner_type_str = clean_type_str.gsub(/^Array\(/, "").gsub(/\)$/, "") %}
              items_schema = {} of String => JSON::Any
              {% if inner_type_str == "String" %}
                items_schema["type"] = JSON::Any.new("string")
              {% elsif inner_type_str == "Int32" %}
                items_schema["type"] = JSON::Any.new("integer")
              {% elsif inner_type_str == "Float64" || inner_type_str == "Float32" %}
                items_schema["type"] = JSON::Any.new("number")
              {% elsif inner_type_str == "Bool" %}
                items_schema["type"] = JSON::Any.new("boolean")
              {% else %}
                # Reference to another schema
                items_schema["$ref"] = JSON::Any.new("#/components/schemas/#{{{inner_type_str}}}")
              {% end %}
              prop_schema["items"] = JSON::Any.new(items_schema)
            {% elsif clean_type_str.starts_with?("Hash(") %}
              prop_schema["type"] = JSON::Any.new("object")
              prop_schema["additionalProperties"] = JSON::Any.new(true)
            {% else %}
              # Complex type - reference another schema
              prop_schema["$ref"] = JSON::Any.new("#/components/schemas/#{{{clean_type_str}}}")
            {% end %}

            # Add nullable if the type was nilable
            {% if is_nilable %}
              prop_schema["nullable"] = JSON::Any.new(true)
            {% end %}

            properties[{{prop_name}}] = JSON::Any.new(prop_schema)
          {% end %}

          schema_hash["properties"] = JSON::Any.new(properties)

          # Add required fields if specified
          {% if required_fields %}
            required_array = {{required_fields}}.map { |field| JSON::Any.new(field.to_s) }
            schema_hash["required"] = JSON::Any.new(required_array)
          {% else %}
            # Auto-detect required fields from non-nilable return types
            required_array = [] of JSON::Any
            {% for method in type_methods %}
              {%
                rt_str = method.return_type.stringify if method.return_type
                is_required = rt_str && !rt_str.includes?("Nil")
              %}
              {% if is_required %}
                required_array << JSON::Any.new({{method.name.stringify}})
              {% end %}
            {% end %}
            schema_hash["required"] = JSON::Any.new(required_array) unless required_array.empty?
          {% end %}

          schema_hash
        end
      {% else %}
        # No Schema annotation, return nil
        nil
      {% end %}
    end

    # Extract all schemas from a module or namespace
    macro extract_schemas_from_module(module_name)
      schemas = {} of String => Hash(String, JSON::Any)

      {%
        module_type = module_name.resolve
      %}

      {% if module_type %}
        {% for const_name in module_type.constants %}
          {%
            const = module_type.constant(const_name)
          %}
          {% if const.annotation(::Micro::Schema) %}
            schema = SchemaExtractor.extract_schema({{module_name}}::{{const_name}})
            if schema
              schemas[{{const_name.stringify}}] = schema
            end
          {% end %}
        {% end %}
      {% end %}

      schemas
    end

    # Helper to extract schema name from a type path
    def self.schema_name_from_path(type_path : String) : String
      # "API::Users::UserResponse" -> "UserResponse"
      type_path.split("::").last
    end

    # Helper to extract all schemas from a list of type paths
    macro extract_schemas(*type_paths)
      schemas = {} of String => Hash(String, JSON::Any)

      {% for type_path in type_paths %}
        {% # Parse the type path to get the simple name

 path_str = type_path.stringify
 type_name = path_str.split("::").last %}

        schema = ::Micro::Gateway::SchemaExtractor.extract_schema({{type_path}})
        if schema
          schemas[{{type_name}}] = schema
        end
      {% end %}

      schemas
    end
  end
end
