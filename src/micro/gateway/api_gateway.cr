# Main API Gateway implementation
require "http/server"
require "../core/service"
require "../core/registry"
require "../stdlib/client"
require "./route"
require "./service_proxy"

module Micro::Gateway
  # Main API Gateway class that routes requests to backend services
  class APIGateway
    Log = ::Log.for(self)

    getter config : Config
    getter routes : RouteRegistry
    getter services : Hash(String, ServiceProxy)
    getter server : HTTP::Server?
    getter started_at : Time

    # Alias for services to match OpenAPI generator expectations
    def service_proxies
      @services
    end

    @cache : Hash(String, CachedResponse)
    @health_checks : Hash(String, HealthStatus)
    @metrics : Metrics

    def initialize(@config : Config)
      @routes = RouteRegistry.new
      @services = {} of String => ServiceProxy
      @cache = {} of String => CachedResponse
      @health_checks = {} of String => HealthStatus
      @metrics = Metrics.new
      @started_at = Time.utc

      setup_services
      setup_routes
    end

    # Start the gateway server
    def run
      handlers = build_handler_chain

      @server = server = HTTP::Server.new(handlers)

      server.bind_tcp(@config.host, @config.port)

      Log.info { "API Gateway starting on #{@config.host}:#{@config.port}" }
      Log.info { "OpenAPI docs: http://#{@config.host}:#{@config.port}#{@config.docs_path}" } if @config.enable_docs?
      Log.info { "Health endpoint: http://#{@config.host}:#{@config.port}#{@config.health_path}" } if @config.health_handler
      Log.info { "Metrics endpoint: http://#{@config.host}:#{@config.port}#{@config.metrics_path}" } if @config.enable_metrics?
      log_registered_routes

      # Start background tasks
      spawn { monitor_services }
      spawn { cleanup_cache }

      server.listen
    end

    # Gracefully shutdown the gateway
    def shutdown(timeout : Time::Span = 30.seconds)
      Log.info { "Shutting down API Gateway..." }

      if server = @server
        server.close
      end

      # Close all service proxies
      @services.each_value(&.close)

      Log.info { "API Gateway shutdown complete" }
    end

    # Get gateway uptime
    def uptime : Time::Span
      Time.utc - @started_at
    end

    # Handle incoming HTTP request
    def handle_request(context : HTTP::Server::Context)
      request = context.request

      # Built-in endpoints: docs, health, metrics
      if @config.enable_docs? && request.method == "GET" && request.path == @config.docs_path
        spec = OpenAPIGenerator.new(self).generate
        context.response.status_code = 200
        context.response.content_type = "application/json"
        context.response.print(spec.to_json)
        return
      end

      if (handler = @config.health_handler) && request.method == "GET" && request.path == @config.health_path
        begin
          result = handler.call
          context.response.status_code = 200
          context.response.content_type = "application/json"
          context.response.print(result.to_json)
        rescue ex
          context.response.status_code = 500
          context.response.content_type = "application/json"
          context.response.print({"error" => "Health check failed", "message" => ex.message}.to_json)
        end
        return
      end

      if @config.enable_metrics? && request.method == "GET" && request.path == @config.metrics_path
        context.response.status_code = 200
        context.response.content_type = "text/plain; version=0.0.4; charset=utf-8"
        context.response.print(@metrics.to_prometheus)
        return
      end

      # Track metrics
      @metrics.request_count += 1
      start_time = Time.monotonic

      begin
        # Find matching route
        route = @routes.find(request.method, request.path)

        unless route
          handle_not_found(context)
          return
        end

        # Check cache if configured
        if cache_config = route.cache_config
          if cached = get_cached_response(route.cache_key(request))
            write_cached_response(context, cached)
            @metrics.cache_hits += 1
            return
          end
          @metrics.cache_misses += 1
        end

        # Execute route handler
        if route.aggregate?
          # Handle aggregated route
          handle_aggregate_route(context, route)
        else
          # Handle standard route
          handle_standard_route(context, route)
        end

        # Cache response if configured
        if cache_config = route.cache_config
          cache_response(route.cache_key(request), context.response, cache_config.ttl)
        end
      rescue ex : ServiceUnavailableError
        handle_service_unavailable(context, ex)
      rescue ex : UnauthorizedError
        handle_unauthorized(context, ex)
      rescue ex
        handle_internal_error(context, ex)
      ensure
        # Track response time
        elapsed = Time.monotonic - start_time
        @metrics.add_response_time(elapsed)
      end
    end

    private def handle_standard_route(context : HTTP::Server::Context, route : Route)
      # Get service proxy
      service = @services[route.service_name]?
      unless service
        raise ServiceUnavailableError.new("Service '#{route.service_name}' not found")
      end

      # Extract path parameters
      params = route.extract_params(context.request.path)

      # Build service request and pass headers for auth propagation
      service_request = build_service_request(context, route, params)

      # Call service
      service_response = service.call(route.service_method, service_request, context.request.headers)

      # Apply transformations
      transformed = apply_transformations(service_response, route.transformations)

      # Write response
      write_json_response(context, transformed)
    end

    private def handle_aggregate_route(context : HTTP::Server::Context, route : Route)
      if handler = route.aggregate_handler
        # Execute custom aggregate handler
        result = handler.call(context)

        # Apply transformations
        transformed = apply_transformations(result, route.transformations)

        # Write response
        write_json_response(context, transformed)
      else
        raise InternalError.new("Aggregate route missing handler")
      end
    end

    private def build_service_request(context : HTTP::Server::Context, route : Route, params : Hash(String, String)) : JSON::Any
      request_body = if body = context.request.body
                       JSON.parse(body)
                     else
                       JSON::Any.new({} of String => JSON::Any)
                     end

      # Merge path params into request
      if request_body.as_h?
        params.each do |key, value|
          request_body.as_h[key] = JSON::Any.new(value)
        end
      end

      request_body
    end

    private def apply_transformations(response : JSON::Any, transformations : Array(ResponseTransformation)) : JSON::Any
      transformations.reduce(response) do |res, transform|
        transform.apply(res)
      end
    end

    private def write_json_response(context : HTTP::Server::Context, data : JSON::Any)
      context.response.content_type = "application/json"
      context.response.print(data.to_json)
    end

    private def write_cached_response(context : HTTP::Server::Context, cached : CachedResponse)
      context.response.status_code = cached.status_code
      cached.headers.each do |key, values|
        values.each do |value|
          context.response.headers.add(key, value)
        end
      end
      context.response.print(cached.body)
    end

    private def handle_not_found(context : HTTP::Server::Context)
      context.response.status_code = 404
      context.response.content_type = "application/json"
      context.response.print({
        "error"   => "Not Found",
        "message" => "The requested endpoint does not exist",
        "path"    => context.request.path,
      }.to_json)
    end

    private def handle_service_unavailable(context : HTTP::Server::Context, error : ServiceUnavailableError)
      context.response.status_code = 503
      context.response.content_type = "application/json"
      context.response.print({
        "error"   => "Service Unavailable",
        "message" => error.message,
      }.to_json)
    end

    private def handle_unauthorized(context : HTTP::Server::Context, error : UnauthorizedError)
      context.response.status_code = 401
      context.response.content_type = "application/json"
      context.response.print({
        "error"   => "Unauthorized",
        "message" => error.message,
      }.to_json)
    end

    private def handle_internal_error(context : HTTP::Server::Context, error : Exception)
      Log.error(exception: error) { "Internal server error" }

      context.response.status_code = 500
      context.response.content_type = "application/json"
      context.response.print({
        "error"   => "Internal Server Error",
        "message" => "An unexpected error occurred",
      }.to_json)
    end

    private def setup_services
      @config.services.each do |name, service_config|
        proxy = ServiceProxy.new(
          name: name,
          config: service_config,
          registry: @config.registry
        )
        @services[name] = proxy
      end
    end

    private def setup_routes
      @config.services.each do |service_name, service_config|
        service_config.routes.each do |route_config|
          # Apply service-level prefix if present
          full_path = if prefix = service_config.prefix
                        prefix + route_config.path
                      else
                        route_config.path
                      end
          route = Route.new(
            method: route_config.method,
            path: full_path,
            service_name: service_name,
            service_method: route_config.service_method,
            request_type: route_config.request_type,
            response_type: route_config.response_type,
            cache_config: (ttl = route_config.cache_ttl) ? CacheConfig.new(ttl: ttl) : nil,
            transformations: route_config.transformations + service_config.transformations,
            public: route_config.public?,
            required_roles: service_config.required_roles
          )
          @routes.register(route)
        end
      end
    end

    private def log_registered_routes
      all_routes = @routes.all
      Log.info { "Registered routes (#{all_routes.size}):" }
      all_routes.each do |r|
        Log.info { "- #{r.method} #{r.path} -> #{r.service_name}.#{r.service_method}" }
      end
    end

    private def build_handler_chain : Array(HTTP::Handler)
      handlers = [] of HTTP::Handler

      # Add CORS if enabled
      if @config.enable_cors?
        if cors = @config.cors_config
          handlers << CORSHandler.new(cors)
        else
          handlers << CORSHandler.new(CORSConfig.new)
        end
      end

      # Add global middleware
      @config.middleware.each do |_|
        # Convert Core::Middleware to HTTP::Handler
        # This would need an adapter
      end

      # Add main gateway handler
      handlers << GatewayHandler.new(self)

      handlers
    end

    private def monitor_services
      loop do
        @services.each do |name, proxy|
          status = proxy.health_check
          @health_checks[name] = status
        end

        sleep 10.seconds
      end
    end

    private def cleanup_cache
      loop do
        now = Time.utc
        @cache.reject! do |_, cached|
          cached.expires_at < now
        end

        sleep 1.minute
      end
    end

    private def get_cached_response(key : String) : CachedResponse?
      if cached = @cache[key]?
        if cached.expires_at > Time.utc
          return cached
        else
          @cache.delete(key)
        end
      end
      nil
    end

    private def cache_response(key : String, response : HTTP::Server::Response, ttl : Time::Span)
      # TODO: Implement response body capture and store in @cache
    end

    # Call a service method (used by aggregate handlers)
    def call(service_name : String, method : String, params : JSON::Any) : JSON::Any
      service = @services[service_name]?
      unless service
        raise ServiceUnavailableError.new("Service '#{service_name}' not found")
      end

      service.call(method, params)
    end
  end

  # Cached response
  struct CachedResponse
    getter status_code : Int32
    getter headers : HTTP::Headers
    getter body : String
    getter expires_at : Time

    def initialize(@status_code, @headers, @body, @expires_at)
    end
  end

  # Health status
  struct HealthStatus
    getter? healthy : Bool
    getter last_check : Time
    getter error : String?

    def initialize(@healthy, @last_check, @error = nil)
    end
  end

  # Gateway metrics
  class Metrics
    property request_count : Int64
    property cache_hits : Int64
    property cache_misses : Int64
    @response_times : Array(Time::Span)

    def initialize
      @request_count = 0_i64
      @cache_hits = 0_i64
      @cache_misses = 0_i64
      @response_times = [] of Time::Span
    end

    def add_response_time(time : Time::Span)
      @response_times << time
      # Keep only last 1000 response times
      @response_times.shift if @response_times.size > 1000
    end

    def average_response_time : Time::Span
      return Time::Span.zero if @response_times.empty?

      total = @response_times.sum
      Time::Span.new(nanoseconds: (total.total_nanoseconds / @response_times.size).to_i64)
    end

    def to_prometheus : String
      String.build do |io|
        io << "# TYPE gateway_requests_total counter\n"
        io << "gateway_requests_total #{@request_count}\n\n"

        io << "# TYPE gateway_cache_hits_total counter\n"
        io << "gateway_cache_hits_total #{@cache_hits}\n\n"

        io << "# TYPE gateway_cache_misses_total counter\n"
        io << "gateway_cache_misses_total #{@cache_misses}\n\n"

        io << "# TYPE gateway_response_time_seconds gauge\n"
        io << "gateway_response_time_seconds #{average_response_time.total_seconds}\n"
      end
    end
  end

  # Gateway HTTP Handler
  class GatewayHandler
    include HTTP::Handler

    def initialize(@gateway : APIGateway)
    end

    def call(context : HTTP::Server::Context)
      @gateway.handle_request(context)
    end
  end

  # Exceptions
  class ServiceUnavailableError < Exception; end

  class UnauthorizedError < Exception; end

  class InternalError < Exception; end
end
