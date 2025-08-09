# Metadata extractor for automatic OpenAPI generation from annotations
require "../annotations"
require "../macros/method_routing"
require "json"

module Micro::Gateway
  # Extracts metadata from service annotations for OpenAPI generation
  module MetadataExtractor
    # Extract service metadata from a service instance
    def self.extract_service_metadata(service : Object) : ServiceMetadata?
      return nil unless service.class.responds_to?(:service_metadata)

      raw_metadata = service.class.service_metadata

      ServiceMetadata.new(
        name: raw_metadata[:name].to_s,
        version: raw_metadata[:version].to_s,
        description: raw_metadata[:description]?.try(&.to_s),
        namespace: raw_metadata[:namespace]?.try(&.to_s),
        tags: extract_array_metadata(raw_metadata[:tags]?),
        contact: extract_hash_metadata(raw_metadata[:contact]?),
        license: extract_hash_metadata(raw_metadata[:license]?),
        terms_of_service: raw_metadata[:terms_of_service]?.try(&.to_s),
        external_docs: extract_hash_metadata(raw_metadata[:external_docs]?)
      )
    end

    # Extract method metadata from a service instance
    def self.extract_method_metadata(service : Object) : Array(MethodMetadata)
      return [] of MethodMetadata unless service.class.responds_to?(:method_routes)

      method_routes = service.class.method_routes

      method_routes.map do |_, method_info|
        MethodMetadata.new(
          name: method_info.name,
          path: method_info.path,
          http_method: method_info.http_method,
          description: method_info.description,
          summary: extract_from_metadata(method_info.metadata, "summary"),
          timeout: method_info.timeout,
          auth_required: method_info.auth_required,
          tags: extract_array_from_metadata(method_info.metadata, "tags"),
          deprecated: extract_bool_from_metadata(method_info.metadata, "deprecated"),
          operation_id: extract_from_metadata(method_info.metadata, "operation_id") || method_info.name,
          consumes: extract_array_from_metadata(method_info.metadata, "consumes") || ["application/json"],
          produces: extract_array_from_metadata(method_info.metadata, "produces") || ["application/json"],
          param_types: method_info.param_types,
          return_type: method_info.return_type,
          request_example: extract_from_metadata(method_info.metadata, "request_example"),
          response_examples: extract_hash_from_metadata(method_info.metadata, "response_examples")
        )
      end.to_a
    end

    # Extract schema metadata from types
    macro extract_schema_metadata(type)
      {% if ann = type.annotation(::Micro::Schema) %}
        SchemaMetadata.new(
          name: {{ann[:name] || type.name.stringify}},
          description: {{ann[:description]}},
          example: {{ann[:example]}},
          required: {{ann[:required] || [] of String}},
          properties: extract_properties_from_type({{type}})
        )
      {% else %}
        SchemaMetadata.new(
          name: {{type.name.stringify}},
          properties: extract_properties_from_type({{type}})
        )
      {% end %}
    end

    # Helper to extract properties from a type
    def self.extract_properties_from_type(type : T.class) : Hash(String, PropertyMetadata) forall T
      properties = {} of String => PropertyMetadata

      {% for ivar in T.instance_vars %}
        properties[{{ivar.name.stringify}}] = PropertyMetadata.new(
          type: crystal_type_to_openapi({{ivar.type.stringify}}),
          description: nil,
          required: !{{ivar.type.nilable?}},
          format: infer_format_from_name({{ivar.name.stringify}})
        )
      {% end %}

      properties
    end

    # Convert Crystal type to OpenAPI type
    def self.crystal_type_to_openapi(crystal_type : String) : String
      case crystal_type
      when /^String/
        "string"
      when /^Int/, /^UInt/
        "integer"
      when /^Float/
        "number"
      when /^Bool/
        "boolean"
      when /^Array/
        "array"
      when /^Hash/
        "object"
      when /^Time/
        "string" # with format: date-time
      when /^UUID/
        "string" # with format: uuid
      else
        "object" # Complex types become objects
      end
    end

    # Infer format from property name
    def self.infer_format_from_name(name : String) : String?
      case name
      when /email/i
        "email"
      when /uuid|id$/i
        "uuid"
      when /url|uri/i
        "uri"
      when /date_?time|created_at|updated_at|timestamp/i
        "date-time"
      when /date/i
        "date"
      when /password/i
        "password"
      when /phone/i
        "phone"
      else
        nil
      end
    end

    private def self.extract_array_metadata(value) : Array(String)
      return [] of String unless value

      case value
      when Array
        value.map(&.to_s)
      else
        [] of String
      end
    end

    private def self.extract_hash_metadata(value) : Hash(String, String)
      return {} of String => String unless value

      case value
      when Hash
        result = {} of String => String
        value.each { |k, v| result[k.to_s] = v.to_s }
        result
      else
        {} of String => String
      end
    end

    private def self.extract_from_metadata(metadata : Hash(String, String), key : String) : String?
      metadata[key]?
    end

    private def self.extract_array_from_metadata(metadata : Hash(String, String), key : String) : Array(String)?
      value = metadata[key]?
      return nil unless value

      # Try to parse as JSON array
      begin
        JSON.parse(value).as_a.map(&.to_s)
      rescue
        # Fall back to comma-separated
        value.split(',').map(&.strip)
      end
    end

    private def self.extract_bool_from_metadata(metadata : Hash(String, String), key : String) : Bool
      value = metadata[key]?
      return false unless value

      value.downcase.in?("true", "yes", "1")
    end

    private def self.extract_hash_from_metadata(metadata : Hash(String, String), key : String) : Hash(String, String)?
      value = metadata[key]?
      return nil unless value

      # Try to parse as JSON object
      begin
        json = JSON.parse(value)
        result = {} of String => String
        json.as_h.each { |k, v| result[k.to_s] = v.to_s }
        result
      rescue
        nil
      end
    end

    # Data structures for holding extracted metadata

    struct ServiceMetadata
      getter name : String
      getter version : String
      getter description : String?
      getter namespace : String?
      getter tags : Array(String)
      getter contact : Hash(String, String)
      getter license : Hash(String, String)
      getter terms_of_service : String?
      getter external_docs : Hash(String, String)

      def initialize(
        @name : String,
        @version : String = "1.0.0",
        @description : String? = nil,
        @namespace : String? = nil,
        @tags : Array(String) = [] of String,
        @contact : Hash(String, String) = {} of String => String,
        @license : Hash(String, String) = {} of String => String,
        @terms_of_service : String? = nil,
        @external_docs : Hash(String, String) = {} of String => String,
      )
      end
    end

    struct MethodMetadata
      getter name : String
      getter path : String
      getter http_method : String
      getter description : String?
      getter summary : String?
      getter timeout : Int32?
      getter? auth_required : Bool
      getter tags : Array(String)?
      getter? deprecated : Bool
      getter operation_id : String
      getter consumes : Array(String)
      getter produces : Array(String)
      getter param_types : Array(String)
      getter return_type : String
      getter request_example : String?
      getter response_examples : Hash(String, String)?

      def initialize(
        @name : String,
        @path : String,
        @http_method : String = "POST",
        @description : String? = nil,
        @summary : String? = nil,
        @timeout : Int32? = nil,
        @auth_required : Bool = false,
        @tags : Array(String)? = nil,
        @deprecated : Bool = false,
        @operation_id : String = "",
        @consumes : Array(String) = ["application/json"],
        @produces : Array(String) = ["application/json"],
        @param_types : Array(String) = [] of String,
        @return_type : String = "Nil",
        @request_example : String? = nil,
        @response_examples : Hash(String, String)? = nil,
      )
      end
    end

    struct SchemaMetadata
      getter name : String
      getter description : String?
      getter example : String?
      getter required : Array(String)
      getter properties : Hash(String, PropertyMetadata)

      def initialize(
        @name : String,
        @description : String? = nil,
        @example : String? = nil,
        @required : Array(String) = [] of String,
        @properties : Hash(String, PropertyMetadata) = {} of String => PropertyMetadata,
      )
      end
    end

    struct PropertyMetadata
      getter type : String
      getter description : String?
      getter? required : Bool
      getter format : String?
      getter example : String?

      def initialize(
        @type : String,
        @description : String? = nil,
        @required : Bool = false,
        @format : String? = nil,
        @example : String? = nil,
      )
      end
    end
  end
end
