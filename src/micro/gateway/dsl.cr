require "../stdlib/registries/memory_registry"
require "../stdlib/registries/consul"
# DSL for building API Gateway configuration
require "./route_builder"

module Micro::Gateway
  # Builder for constructing gateway configuration with DSL
  class Builder
    getter config : Config
    @current_service : ServiceConfig?
    @route_builders : Array(RouteBuilder)

    def initialize
      @config = Config.new
      @route_builders = [] of RouteBuilder
    end

    # Set gateway name
    def name(value : String)
      @config.name = value
    end

    # Set gateway version
    def version(value : String)
      @config.version = value
    end

    # Set host binding
    def host(value : String)
      @config.host = value
    end

    # Set port
    def port(value : Int32)
      @config.port = value
    end

    # Configure registry with block
    def registry(type : Symbol, &)
      case type
      when :consul
        consul_builder = ConsulBuilder.new
        with consul_builder yield
        @config.registry = consul_builder.build
      when :memory
        # Use stdlib in-memory registry with default options
        @config.registry = Micro::Stdlib::Registries::MemoryRegistry.new(Micro::Core::Registry::Options.new)
      else
        raise "Unknown registry type: #{type}"
      end
    end

    # Configure registry with an existing instance
    def registry(registry_instance : Core::Registry::Base)
      @config.registry = registry_instance
    end

    # Configure a service
    def service(name : String, &)
      service_name = name

      service_config = ServiceConfig.new
      service_builder = ServiceBuilder.new(service_name, service_config)
      with service_builder yield

      @config.add_service(service_name, service_config)

      # Store route builders for later processing
      @route_builders.concat(service_builder.route_builders)
    end

    # Configure documentation
    def documentation(&)
      docs_builder = DocsBuilder.new(@config)
      with docs_builder yield
    end

    # Configure health check
    def health_check(&block : -> HealthCheckResponse)
      # Store health check handler
      @config.health_handler = block
    end

    # Build the final gateway
    def build : APIGateway
      gateway = APIGateway.new(@config)

      gateway
    end
  end

  # Builder for service configuration
  class ServiceBuilder
    getter service_name : String
    getter config : ServiceConfig
    getter route_builders : Array(RouteBuilder)

    def initialize(@service_name : String, @config : ServiceConfig)
      @route_builders = [] of RouteBuilder
    end

    # Expose specific methods
    def expose(*methods : Symbol)
      @config.exposed_methods = methods.map(&.to_s).to_a
    end

    # Expose all methods
    def expose_all
      @config.exposed_methods = nil
      @config.blocked_methods = nil
    end

    # Block specific methods
    def block(*methods : Symbol)
      @config.blocked_methods = methods.map(&.to_s).to_a
    end

    # Set service version preference
    def version(value : String)
      @config.version = value
    end

    # Set URL prefix for all routes
    def prefix(value : String)
      @config.prefix = value
    end

    # Set timeout for service calls
    def timeout(value : Time::Span)
      @config.timeout = value
    end

    # Configure RESTful routes
    def rest_routes(base_path : String, &)
      rest_builder = RestRoutesBuilder.new(@service_name, base_path)
      with rest_builder yield

      rest_builder.routes.each do |route_config|
        builder = RouteBuilder.new(
          service_name: @service_name,
          method: route_config.method,
          path: route_config.path,
          service_method: route_config.service_method
        )
        @route_builders << builder
        @config.add_route(route_config)
      end
    end

    # Add custom route
    def route(method : String, path : String, to service_method : String)
      route_config = RouteConfig.new(
        method: method,
        path: path,
        service_method: service_method
      )
      @config.add_route(route_config)

      builder = RouteBuilder.new(
        service_name: @service_name,
        method: method,
        path: path,
        service_method: service_method
      )
      @route_builders << builder
    end

    # Configure caching for methods
    def cache(*methods : Symbol, ttl : Time::Span)
      # Add cache configuration for specified methods
      methods.each do |method|
        @config.routes.each do |route|
          if route.service_method == method.to_s
            route.cache_ttl = ttl
          end
        end
      end
    end

    # Require authentication for service
    def require_auth(value : Bool = true)
      @config.require_auth = value
    end

    # Require specific role
    def require_role(role, for methods : Array(Symbol)? = nil)
      if methods
        # Apply to specific methods
        methods.each do |method|
          @config.routes.each do |route|
            if route.service_method == method.to_s
              route.required_roles = [role.to_s]
            end
          end
        end
      else
        # Apply to all methods
        @config.required_roles = [role.to_s]
      end
    end

    # Configure circuit breaker
    def circuit_breaker(&)
      breaker_builder = CircuitBreakerBuilder.new
      with breaker_builder yield
      @config.circuit_breaker = breaker_builder.build
    end

    # Configure retry policy
    def retry_policy(&)
      retry_builder = RetryPolicyBuilder.new
      with retry_builder yield
      @config.retry_policy = retry_builder.build
    end

    # Add response transformation
    def transform_response(&block : JSON::Any -> JSON::Any)
      transformation = ResponseTransformation.new(
        type: ResponseTransformation::TransformationType::Custom,
        custom_handler: block
      )
      @config.transformations << transformation
    end

    # Define aggregation route
    def aggregate(method : Symbol, path : String, &)
      # Create aggregate route builder
      aggregate_builder = AggregateRouteBuilder.new(
        service_name: @service_name,
        method: method.to_s.upcase,
        path: path
      )
      with aggregate_builder yield

      # Create route with aggregate handler
      route_config = RouteConfig.new(
        method: method.to_s.upcase,
        path: path,
        service_method: "_aggregate_#{method}",
        aggregate: true,
        aggregate_handler: aggregate_builder.handler
      )
      @config.add_route(route_config)
    end
  end

  # Builder for RESTful routes
  class RestRoutesBuilder
    getter routes : Array(RouteConfig)

    def initialize(@service_name : String, @base_path : String)
      @routes = [] of RouteConfig
    end

    # GET /resources -> list method
    def index(method : Symbol)
      @routes << RouteConfig.new(
        method: "GET",
        path: @base_path,
        service_method: method.to_s
      )
    end

    # GET /resources/:id -> show method
    def show(method : Symbol)
      @routes << RouteConfig.new(
        method: "GET",
        path: "#{@base_path}/:id",
        service_method: method.to_s
      )
    end

    # POST /resources -> create method
    def create(method : Symbol)
      @routes << RouteConfig.new(
        method: "POST",
        path: @base_path,
        service_method: method.to_s
      )
    end

    # PUT /resources/:id -> update method
    def update(method : Symbol)
      @routes << RouteConfig.new(
        method: "PUT",
        path: "#{@base_path}/:id",
        service_method: method.to_s
      )
    end

    # DELETE /resources/:id -> destroy method
    def destroy(method : Symbol)
      @routes << RouteConfig.new(
        method: "DELETE",
        path: "#{@base_path}/:id",
        service_method: method.to_s
      )
    end
  end

  # Builder for Consul registry
  class ConsulBuilder
    property address : String = "localhost:8500"
    property datacenter : String = "dc1"
    property token : String? = nil
    property scheme : String = "http"

    def build : Core::Registry::Base
      # Construct a Consul registry using provided settings
      # Fallback to defaults inside ConsulRegistry
      options = Micro::Core::Registry::Options.new(
        type: "consul",
        addresses: [address],
        secure: scheme == "https"
      )
      Micro::Stdlib::Registries::ConsulRegistry.new(options)
    end
  end

  # Builder for documentation
  class DocsBuilder
    def initialize(@config : Config)
    end

    def title(value : String)
      @config.docs_title = value
    end

    def version(value : String)
      @config.docs_version = value
    end

    def description(value : String)
      @config.docs_description = value
    end

    def auto_generate_schemas(types : Array(String))
      # Store types for schema generation
      @config.schema_types = types
    end

    def security(name : Symbol, &_block)
      # Configure security schemes
    end
  end

  # Builder for circuit breaker configuration
  class CircuitBreakerBuilder
    @failure_threshold : Int32 = 5
    @success_threshold : Int32 = 2
    @timeout : Time::Span = 30.seconds
    @half_open_requests : Int32 = 3

    def failure_threshold(value : Int32)
      @failure_threshold = value
    end

    def success_threshold(value : Int32)
      @success_threshold = value
    end

    def timeout(value : Time::Span)
      @timeout = value
    end

    def half_open_requests(value : Int32)
      @half_open_requests = value
    end

    def build : CircuitBreakerConfig
      CircuitBreakerConfig.new(
        failure_threshold: @failure_threshold,
        success_threshold: @success_threshold,
        timeout: @timeout,
        half_open_requests: @half_open_requests
      )
    end
  end

  # Builder for retry policy configuration
  class RetryPolicyBuilder
    @max_attempts : Int32 = 3
    @backoff : Time::Span = 1.second
    @backoff_multiplier : Float64 = 2.0
    @max_backoff : Time::Span = 30.seconds

    def max_attempts(value : Int32)
      @max_attempts = value
    end

    def backoff(value : Time::Span)
      @backoff = value
    end

    def backoff_multiplier(value : Float64)
      @backoff_multiplier = value
    end

    def max_backoff(value : Time::Span)
      @max_backoff = value
    end

    def build : RetryPolicy
      RetryPolicy.new(
        max_attempts: @max_attempts,
        backoff: @backoff,
        backoff_multiplier: @backoff_multiplier,
        max_backoff: @max_backoff
      )
    end
  end
end
