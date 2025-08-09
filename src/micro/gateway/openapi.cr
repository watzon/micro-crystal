# OpenAPI specification generator for API Gateway
require "json"
require "./metadata_extractor"

module Micro::Gateway
  # Generates OpenAPI 3.0 specification from gateway routes
  class OpenAPIGenerator
    Log = ::Log.for(self)

    getter gateway : APIGateway
    getter config : OpenAPIConfig
    getter? auto_extract : Bool

    def initialize(@gateway : APIGateway, @config : OpenAPIConfig = OpenAPIConfig.new, @auto_extract : Bool = true)
    end

    # Generate OpenAPI specification
    def generate : JSON::Any
      # Extract metadata from services if auto-extract is enabled
      extract_metadata_from_services if @auto_extract

      spec = {} of String => JSON::Any

      spec["openapi"] = JSON::Any.new("3.0.3")
      spec["info"] = JSON::Any.new(generate_info)
      spec["servers"] = JSON::Any.new(generate_servers)
      spec["paths"] = JSON::Any.new(generate_paths)
      spec["components"] = JSON::Any.new(generate_components)
      spec["security"] = JSON::Any.new(generate_security)

      JSON::Any.new(spec)
    end

    # Extract metadata from registered services and their methods
    private def extract_metadata_from_services
      # For each service proxy in the gateway
      @gateway.service_proxies.each do |_, proxy|
        # Try to get actual service instance metadata if available
        # This would be populated by service discovery
        if service = proxy.service_instance?
          if service_metadata = MetadataExtractor.extract_service_metadata(service)
            # Update config with extracted metadata
            @config.title ||= service_metadata.name
            @config.description ||= service_metadata.description
            @config.version ||= service_metadata.version

            # Add tags
            service_metadata.tags.each do |tag|
              @config.tags << tag unless @config.tags.includes?(tag)
            end

            # Update contact and license if provided
            @config.contact = service_metadata.contact unless service_metadata.contact.empty?
            @config.license = service_metadata.license unless service_metadata.license.empty?
          end

          # Extract method metadata
          methods = MetadataExtractor.extract_method_metadata(service)
          methods.each do |method|
            # Update route with extracted metadata
            if route = @gateway.routes.find(method.path, method.http_method)
              route.description ||= method.description
              route.summary = method.summary
              route.deprecated = method.deprecated
              route.operation_id = method.operation_id
              route.tags = method.tags || [proxy.name]
              route.consumes = method.consumes
              route.produces = method.produces
              route.request_example = method.request_example
              route.response_examples = method.response_examples
            end
          end
        end
      end
    rescue ex
      Log.warn { "Failed to extract metadata from services: #{ex.message}" }
    end

    private def generate_info : Hash(String, JSON::Any)
      info = {
        "title"       => JSON::Any.new(@config.title),
        "description" => JSON::Any.new(@config.description),
        "version"     => JSON::Any.new(@config.version),
      } of String => JSON::Any

      # Convert contact hash to JSON::Any
      unless @config.contact.empty?
        contact_hash = {} of String => JSON::Any
        @config.contact.each { |k, v| contact_hash[k] = JSON::Any.new(v) }
        info["contact"] = JSON::Any.new(contact_hash)
      end

      # Convert license hash to JSON::Any
      unless @config.license.empty?
        license_hash = {} of String => JSON::Any
        @config.license.each { |k, v| license_hash[k] = JSON::Any.new(v) }
        info["license"] = JSON::Any.new(license_hash)
      end

      info
    end

    private def generate_servers : Array(JSON::Any)
      @config.servers.map do |server|
        JSON::Any.new({
          "url"         => JSON::Any.new(server.url),
          "description" => JSON::Any.new(server.description),
        } of String => JSON::Any)
      end
    end

    private def generate_paths : Hash(String, JSON::Any)
      paths = {} of String => JSON::Any

      # Group routes by path
      routes_by_path = @gateway.routes.all.group_by(&.path)

      routes_by_path.each do |path, routes|
        path_item = {} of String => JSON::Any

        routes.each do |route|
          operation = generate_operation(route)
          path_item[route.method.downcase] = JSON::Any.new(operation)
        end

        # Convert path parameters from :param to {param}
        openapi_path = path.gsub(/:(\w+)/, "{\\1}")
        paths[openapi_path] = JSON::Any.new(path_item)
      end

      paths
    end

    private def generate_operation(route : Route) : Hash(String, JSON::Any)
      operation = {} of String => JSON::Any

      operation["operationId"] = JSON::Any.new("#{route.service_name}_#{route.service_method}")
      operation["summary"] = JSON::Any.new("#{route.service_method} on #{route.service_name}")
      operation["tags"] = JSON::Any.new([JSON::Any.new(route.service_name)])

      # Add description if available
      if description = get_method_description(route)
        operation["description"] = JSON::Any.new(description)
      end

      # Add parameters
      parameters = generate_parameters(route)
      operation["parameters"] = JSON::Any.new(parameters) unless parameters.empty?

      # Add request body for POST/PUT/PATCH
      if route.method.in?("POST", "PUT", "PATCH")
        operation["requestBody"] = JSON::Any.new(generate_request_body(route))
      end

      # Add responses
      operation["responses"] = JSON::Any.new(generate_responses(route))

      # Add security requirements
      unless route.public?
        security_arr = [JSON::Any.new({"bearerAuth" => JSON::Any.new([] of JSON::Any)} of String => JSON::Any)]
        operation["security"] = JSON::Any.new(security_arr)
      end

      operation
    end

    private def generate_parameters(route : Route) : Array(JSON::Any)
      parameters = [] of JSON::Any

      # Extract path parameters
      path_params = route.path.scan(/:(\w+)/).map(&.[1])

      path_params.each do |param|
        param_obj = {} of String => JSON::Any
        param_obj["name"] = JSON::Any.new(param)
        param_obj["in"] = JSON::Any.new("path")
        param_obj["required"] = JSON::Any.new(true)
        param_obj["schema"] = JSON::Any.new({
          "type" => JSON::Any.new(infer_param_type(param)),
        } of String => JSON::Any)

        parameters << JSON::Any.new(param_obj)
      end

      # Add query parameters if configured
      if query_params = @config.route_query_params[route.path]?
        query_params.each do |param|
          param_obj = {} of String => JSON::Any
          param_obj["name"] = JSON::Any.new(param.name)
          param_obj["in"] = JSON::Any.new("query")
          param_obj["required"] = JSON::Any.new(param.required)
          param_obj["description"] = JSON::Any.new(param.description)
          param_obj["schema"] = JSON::Any.new({
            "type" => JSON::Any.new(param.type),
          } of String => JSON::Any)

          parameters << JSON::Any.new(param_obj)
        end
      end

      parameters
    end

    private def generate_request_body(route : Route) : Hash(String, JSON::Any)
      schema = if request_type = route.request_type
                 JSON::Any.new({
                   "$ref" => JSON::Any.new("#/components/schemas/#{request_type.split("::").last}"),
                 } of String => JSON::Any)
               else
                 JSON::Any.new({"type" => JSON::Any.new("object")} of String => JSON::Any)
               end

      {
        "required" => JSON::Any.new(true),
        "content"  => JSON::Any.new({
          "application/json" => JSON::Any.new({
            "schema" => schema,
          } of String => JSON::Any),
        } of String => JSON::Any),
      }
    end

    private def generate_responses(route : Route) : Hash(String, JSON::Any)
      responses = {} of String => JSON::Any

      # Success response
      success_schema = if response_type = route.response_type
                         JSON::Any.new({
                           "$ref" => JSON::Any.new("#/components/schemas/#{response_type.split("::").last}"),
                         } of String => JSON::Any)
                       else
                         JSON::Any.new({"type" => JSON::Any.new("object")} of String => JSON::Any)
                       end

      responses["200"] = JSON::Any.new({
        "description" => JSON::Any.new("Successful response"),
        "content"     => JSON::Any.new({
          "application/json" => JSON::Any.new({
            "schema" => success_schema,
          } of String => JSON::Any),
        } of String => JSON::Any),
      } of String => JSON::Any)

      # Error responses
      error_schema = JSON::Any.new({
        "$ref" => JSON::Any.new("#/components/schemas/Error"),
      } of String => JSON::Any)

      responses["400"] = JSON::Any.new({
        "description" => JSON::Any.new("Bad Request"),
        "content"     => JSON::Any.new({
          "application/json" => JSON::Any.new({
            "schema" => error_schema,
          } of String => JSON::Any),
        } of String => JSON::Any),
      } of String => JSON::Any)

      unless route.public?
        responses["401"] = JSON::Any.new({
          "description" => JSON::Any.new("Unauthorized"),
          "content"     => JSON::Any.new({
            "application/json" => JSON::Any.new({
              "schema" => error_schema,
            } of String => JSON::Any),
          } of String => JSON::Any),
        } of String => JSON::Any)
      end

      responses["500"] = JSON::Any.new({
        "description" => JSON::Any.new("Internal Server Error"),
        "content"     => JSON::Any.new({
          "application/json" => JSON::Any.new({
            "schema" => error_schema,
          } of String => JSON::Any),
        } of String => JSON::Any),
      } of String => JSON::Any)

      responses
    end

    private def generate_components : Hash(String, JSON::Any)
      {
        "schemas"         => JSON::Any.new(generate_schemas),
        "securitySchemes" => JSON::Any.new(generate_security_schemes),
      }
    end

    private def generate_schemas : Hash(String, JSON::Any)
      schemas = {} of String => JSON::Any

      # Add error schema
      error_props = {} of String => JSON::Any
      error_props["error"] = JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any)
      error_props["message"] = JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any)

      schemas["Error"] = JSON::Any.new({
        "type"       => JSON::Any.new("object"),
        "properties" => JSON::Any.new(error_props),
      } of String => JSON::Any)

      # Add custom schemas
      @config.schemas.each do |name, schema|
        schemas[name] = JSON::Any.new(schema)
      end

      # Auto-generate schemas from types if configured
      # This would use Crystal's macro system to introspect types

      schemas
    end

    private def generate_security_schemes : Hash(String, JSON::Any)
      schemes = {} of String => JSON::Any

      schemes["bearerAuth"] = JSON::Any.new({
        "type"         => JSON::Any.new("http"),
        "scheme"       => JSON::Any.new("bearer"),
        "bearerFormat" => JSON::Any.new("JWT"),
      } of String => JSON::Any)

      # Add custom security schemes
      @config.security_schemes.each do |name, scheme|
        schemes[name] = JSON::Any.new(scheme)
      end

      schemes
    end

    private def generate_security : Array(JSON::Any)
      # Global security requirements
      if @config.require_auth_by_default?
        [JSON::Any.new({"bearerAuth" => JSON::Any.new([] of JSON::Any)} of String => JSON::Any)]
      else
        [] of JSON::Any
      end
    end

    private def get_method_description(route : Route) : String?
      # This would look up method documentation from annotations
      # or a documentation registry
      nil
    end

    private def infer_param_type(param_name : String) : String
      case param_name
      when "id", "user_id", "product_id"
        "string" # Could be UUID
      when "page", "limit", "offset", "count"
        "integer"
      when "active", "enabled", "public"
        "boolean"
      else
        "string"
      end
    end
  end

  # OpenAPI configuration
  class OpenAPIConfig
    property title : String
    property description : String
    property version : String
    property servers : Array(ServerInfo)
    property contact : Hash(String, String)
    property license : Hash(String, String)
    property schemas : Hash(String, Hash(String, JSON::Any))
    property security_schemes : Hash(String, Hash(String, JSON::Any))
    property route_query_params : Hash(String, Array(QueryParam))
    property? require_auth_by_default : Bool
    property tags : Array(String)

    def initialize(
      @title : String = "API Gateway",
      @description : String = "API Gateway for microservices",
      @version : String = "1.0.0",
      @servers : Array(ServerInfo) = [] of ServerInfo,
      @contact : Hash(String, String) = {} of String => String,
      @license : Hash(String, String) = {} of String => String,
      @schemas : Hash(String, Hash(String, JSON::Any)) = {} of String => Hash(String, JSON::Any),
      @security_schemes : Hash(String, Hash(String, JSON::Any)) = {} of String => Hash(String, JSON::Any),
      @route_query_params : Hash(String, Array(QueryParam)) = {} of String => Array(QueryParam),
      @require_auth_by_default : Bool = true,
      @tags : Array(String) = [] of String,
    )
    end

    # Add a server
    def add_server(url : String, description : String)
      @servers << ServerInfo.new(url, description)
    end

    # Add a schema
    def add_schema(name : String, schema : Hash(String, JSON::Any))
      @schemas[name] = schema
    end

    # Add query parameters for a route
    def add_query_params(path : String, params : Array(QueryParam))
      @route_query_params[path] = params
    end
  end

  # Server information
  struct ServerInfo
    getter url : String
    getter description : String

    def initialize(@url : String, @description : String)
    end
  end

  # Query parameter definition
  struct QueryParam
    getter name : String
    getter type : String
    getter required : Bool
    getter description : String

    def initialize(
      @name : String,
      @type : String = "string",
      @required : Bool = false,
      @description : String = "",
    )
    end
  end
end
