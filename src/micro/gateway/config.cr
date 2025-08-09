# Gateway configuration
module Micro::Gateway
  # Configuration for the API Gateway
  class Config
    property name : String
    property version : String
    property host : String
    property port : Int32
    property registry : Core::Registry::Base?
    property? enable_docs : Bool
    property docs_path : String
    property middleware : Array(Core::Middleware)
    property services : Hash(String, ServiceConfig)
    property global_headers : HTTP::Headers
    property? enable_metrics : Bool
    property metrics_path : String
    property health_path : String
    property request_timeout : Time::Span
    property? enable_cors : Bool
    property cors_config : CORSConfig?
    property health_handler : Proc(HealthCheckResponse)?
    property docs_title : String
    property docs_version : String
    property docs_description : String
    property schema_types : Array(String)?

    def initialize(
      @name : String = "api-gateway",
      @version : String = "1.0.0",
      @host : String = "0.0.0.0",
      @port : Int32 = 8080,
      @registry : Core::Registry::Base? = nil,
      @enable_docs : Bool = false,
      @docs_path : String = "/api/docs",
      @middleware : Array(Core::Middleware) = [] of Core::Middleware,
      @services : Hash(String, ServiceConfig) = {} of String => ServiceConfig,
      @global_headers : HTTP::Headers = HTTP::Headers.new,
      @enable_metrics : Bool = false,
      @metrics_path : String = "/metrics",
      @health_path : String = "/health",
      @request_timeout : Time::Span = 30.seconds,
      @enable_cors : Bool = true,
      @cors_config : CORSConfig? = nil,
      @health_handler : Proc(HealthCheckResponse)? = nil,
      @docs_title : String = "API Gateway",
      @docs_version : String = "1.0.0",
      @docs_description : String = "",
      @schema_types : Array(String)? = nil,
    )
    end

    # Add a service configuration
    def add_service(name : String, config : ServiceConfig)
      @services[name] = config
    end

    # Get service configuration
    def service(name : String) : ServiceConfig?
      @services[name]?
    end
  end

  # Configuration for a specific service
  class ServiceConfig
    property version : String?
    property prefix : String?
    property timeout : Time::Span
    property retry_policy : RetryPolicy?
    property circuit_breaker : CircuitBreakerConfig?
    property exposed_methods : Array(String)?
    property blocked_methods : Array(String)?
    property transformations : Array(ResponseTransformation)
    property middleware : Array(Core::Middleware)
    property routes : Array(RouteConfig)
    property? require_auth : Bool
    property required_roles : Array(String)
    property cache_config : CacheConfig?

    def initialize(
      @version : String? = nil,
      @prefix : String? = nil,
      @timeout : Time::Span = 10.seconds,
      @retry_policy : RetryPolicy? = nil,
      @circuit_breaker : CircuitBreakerConfig? = nil,
      @exposed_methods : Array(String)? = nil,
      @blocked_methods : Array(String)? = nil,
      @transformations : Array(ResponseTransformation) = [] of ResponseTransformation,
      @middleware : Array(Core::Middleware) = [] of Core::Middleware,
      @routes : Array(RouteConfig) = [] of RouteConfig,
      @require_auth : Bool = true,
      @required_roles : Array(String) = [] of String,
      @cache_config : CacheConfig? = nil,
    )
    end

    # Check if a method is exposed
    def method_exposed?(method : String) : Bool
      # If exposed_methods is set, only those are allowed
      if exposed = @exposed_methods
        return exposed.includes?(method)
      end

      # If blocked_methods is set, everything except those is allowed
      if blocked = @blocked_methods
        return !blocked.includes?(method)
      end

      # Default to allowing all methods
      true
    end

    # Add a custom route
    def add_route(route : RouteConfig)
      @routes << route
    end
  end

  # Route configuration
  class RouteConfig
    property method : String
    property path : String
    property service_method : String
    property request_type : String?
    property response_type : String?
    property? public : Bool
    property cache_ttl : Time::Span?
    property transformations : Array(ResponseTransformation)
    property required_roles : Array(String)
    property? aggregate : Bool
    property aggregate_handler : Proc(HTTP::Server::Context, JSON::Any)?

    def initialize(
      @method : String,
      @path : String,
      @service_method : String,
      @request_type : String? = nil,
      @response_type : String? = nil,
      @public : Bool = false,
      @cache_ttl : Time::Span? = nil,
      @transformations : Array(ResponseTransformation) = [] of ResponseTransformation,
      @required_roles : Array(String) = [] of String,
      @aggregate : Bool = false,
      @aggregate_handler : Proc(HTTP::Server::Context, JSON::Any)? = nil,
    )
    end
  end

  # Response transformation configuration
  class ResponseTransformation
    property type : TransformationType
    property fields_to_remove : Array(String)?
    property fields_to_add : Hash(String, JSON::Any)?
    property custom_handler : Proc(JSON::Any, JSON::Any)?

    enum TransformationType
      RemoveFields
      AddFields
      Custom
    end

    def initialize(
      @type : TransformationType,
      @fields_to_remove : Array(String)? = nil,
      @fields_to_add : Hash(String, JSON::Any)? = nil,
      @custom_handler : Proc(JSON::Any, JSON::Any)? = nil,
    )
    end

    # Apply transformation to response
    def apply(response : JSON::Any) : JSON::Any
      case @type
      when .remove_fields?
        remove_fields(response)
      when .add_fields?
        add_fields(response)
      when .custom?
        @custom_handler.try(&.call(response)) || response
      else
        response
      end
    end

    private def remove_fields(response : JSON::Any) : JSON::Any
      return response unless fields = @fields_to_remove

      if obj = response.as_h?
        filtered = obj.dup
        fields.each { |field| filtered.delete(field) }
        JSON::Any.new(filtered)
      else
        response
      end
    end

    private def add_fields(response : JSON::Any) : JSON::Any
      return response unless fields = @fields_to_add

      if obj = response.as_h?
        updated = obj.dup
        fields.each { |key, value| updated[key] = value }
        JSON::Any.new(updated)
      else
        response
      end
    end
  end

  # Retry policy configuration
  class RetryPolicy
    property max_attempts : Int32
    property backoff : Time::Span
    property backoff_multiplier : Float64
    property max_backoff : Time::Span

    def initialize(
      @max_attempts : Int32 = 3,
      @backoff : Time::Span = 1.second,
      @backoff_multiplier : Float64 = 2.0,
      @max_backoff : Time::Span = 30.seconds,
    )
    end
  end

  # Circuit breaker configuration
  class CircuitBreakerConfig
    property failure_threshold : Int32
    property success_threshold : Int32
    property timeout : Time::Span
    property half_open_requests : Int32

    def initialize(
      @failure_threshold : Int32 = 5,
      @success_threshold : Int32 = 2,
      @timeout : Time::Span = 30.seconds,
      @half_open_requests : Int32 = 3,
    )
    end
  end

  # Cache configuration
  class CacheConfig
    property ttl : Time::Span
    property key_prefix : String
    property vary_by : Array(String)

    def initialize(
      @ttl : Time::Span = 1.minute,
      @key_prefix : String = "",
      @vary_by : Array(String) = ["path", "query"],
    )
    end
  end

  # Health check response type
  struct HealthCheckResponse
    include JSON::Serializable

    getter status : Symbol
    getter services : Hash(String, Bool)
    getter uptime : Float64

    def initialize(@status : Symbol, @services : Hash(String, Bool), @uptime : Float64)
    end
  end

  # CORS configuration
  class CORSConfig
    property allowed_origins : Array(String)
    property allowed_methods : Array(String)
    property allowed_headers : Array(String)
    property exposed_headers : Array(String)
    property max_age : Int32
    property? allow_credentials : Bool

    def initialize(
      @allowed_origins : Array(String) = ["*"],
      @allowed_methods : Array(String) = ["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"],
      @allowed_headers : Array(String) = ["*"],
      @exposed_headers : Array(String) = [] of String,
      @max_age : Int32 = 86400,
      @allow_credentials : Bool = false,
    )
    end
  end
end
