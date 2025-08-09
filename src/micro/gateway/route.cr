# Route definitions for the API Gateway
require "radix"

module Micro::Gateway
  # Represents a single route in the gateway
  class Route
    property method : String
    property path : String
    property service_name : String
    property service_method : String
    property request_type : String?
    property response_type : String?
    property middleware : Array(::Micro::Core::Middleware)
    property cache_config : CacheConfig?
    property transformations : Array(ResponseTransformation)
    property? public : Bool
    property required_roles : Array(String)
    property? aggregate : Bool
    property aggregate_handler : Proc(HTTP::Server::Context, JSON::Any)?

    # OpenAPI metadata fields
    property description : String?
    property summary : String?
    property? deprecated : Bool
    property operation_id : String
    property tags : Array(String)?
    property consumes : Array(String)
    property produces : Array(String)
    property request_example : String?
    property response_examples : Hash(String, String)?

    def initialize(
      @method : String,
      @path : String,
      @service_name : String,
      @service_method : String,
      @request_type : String? = nil,
      @response_type : String? = nil,
      @middleware : Array(::Micro::Core::Middleware) = [] of ::Micro::Core::Middleware,
      @cache_config : CacheConfig? = nil,
      @transformations : Array(ResponseTransformation) = [] of ResponseTransformation,
      @public : Bool = false,
      @required_roles : Array(String) = [] of String,
      @aggregate : Bool = false,
      @aggregate_handler : Proc(HTTP::Server::Context, JSON::Any)? = nil,
      @description : String? = nil,
      @summary : String? = nil,
      @deprecated : Bool = false,
      @operation_id : String = "",
      @tags : Array(String)? = nil,
      @consumes : Array(String) = ["application/json"],
      @produces : Array(String) = ["application/json"],
      @request_example : String? = nil,
      @response_examples : Hash(String, String)? = nil,
    )
      # Default operation_id if not provided
      @operation_id = "#{@service_name}_#{@service_method}" if @operation_id.empty?
    end

    # Check if route matches request
    def matches?(request_method : String, request_path : String) : Bool
      return false unless @method == request_method || @method == "ANY"

      # Simple path matching for now, will use Radix tree later
      path_pattern = @path.gsub(/:(\w+)/, "(?<\\1>[^/]+)")
      regex = Regex.new("^#{path_pattern}$")
      regex.matches?(request_path)
    end

    # Extract path parameters
    def extract_params(request_path : String) : Hash(String, String)
      params = {} of String => String

      path_pattern = @path.gsub(/:(\w+)/, "(?<\\1>[^/]+)")
      regex = Regex.new("^#{path_pattern}$")

      if match = regex.match(request_path)
        match.named_captures.each do |name, value|
          params[name] = value if value
        end
      end

      params
    end

    # Generate cache key for this route
    def cache_key(request : HTTP::Request) : String
      parts = [@service_name, @service_method]

      if config = @cache_config
        config.vary_by.each do |vary|
          case vary
          when "path"
            parts << request.path
          when "query"
            parts << (request.query || "")
          when "headers"
            parts << request.headers.to_h.to_json
          end
        end
      end

      parts.join(":")
    end
  end

  # Manages collection of routes
  class RouteRegistry
    @routes : Array(Route)
    @tree : Radix::Tree(Route)

    def initialize
      @routes = [] of Route
      @tree = Radix::Tree(Route).new
    end

    # Register a new route
    def register(route : Route)
      @routes << route

      # Add to radix tree for efficient matching
      tree_key = "#{route.method}:#{route.path}"

      # Check if route already exists
      unless @tree.find(tree_key)
        @tree.add(tree_key, route)
      end
    end

    # Find matching route for request
    def find(method : String, path : String) : Route?
      # Try exact match first
      tree_key = "#{method}:#{path}"
      if result = @tree.find(tree_key)
        return result.payload? if result.found?
      end

      # Fall back to pattern matching for parameterized routes
      @routes.find(&.matches?(method, path))
    end

    # Get all routes
    def all : Array(Route)
      @routes
    end

    # Get routes for a specific service
    def for_service(service_name : String) : Array(Route)
      @routes.select { |route| route.service_name == service_name }
    end

    # Clear all routes
    def clear
      @routes.clear
      @tree = Radix::Tree(Route).new
    end
  end
end
