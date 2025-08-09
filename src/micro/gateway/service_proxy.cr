# Service proxy for backend service communication
require "../core/registry"
require "../stdlib/client"
require "../stdlib/transports/http"
require "json"

module Micro::Gateway
  # Proxy for communicating with backend microservices
  class ServiceProxy
    Log = ::Log.for(self)

    getter name : String
    getter config : ServiceConfig

    @client : Stdlib::Client?
    @registry : Core::Registry::Base?
    @circuit_breaker : CircuitBreaker?
    @last_health_check : Time
    @healthy : Bool
    # Store service metadata for OpenAPI generation
    @service_metadata : NamedTuple(name: String, version: String, methods: Array(NamedTuple(
      name: String,
      path: String,
      method: String,
      description: String?,
      tags: Array(String)?)))?

    def initialize(@name : String, @config : ServiceConfig, @registry : Core::Registry::Base? = nil)
      @last_health_check = Time.utc
      @healthy = true
      @service_metadata = nil

      setup_client
      setup_circuit_breaker
    end

    # Get the service metadata if available (for OpenAPI generation)
    def service_instance?
      nil # For now, return nil since we can't store generic objects
    end

    # Get service metadata for OpenAPI generation
    def service_metadata
      @service_metadata
    end

    # Set service metadata (used by service discovery or manual configuration)
    def service_metadata=(metadata)
      @service_metadata = metadata
    end

    # Call a method on the backend service
    def call(method : String, params : JSON::Any, headers : HTTP::Headers? = nil) : JSON::Any
      # Check if method is exposed
      unless @config.method_exposed?(method)
        raise MethodNotAllowedError.new("Method '#{method}' is not exposed for service '#{@name}'")
      end

      # Check circuit breaker
      if breaker = @circuit_breaker
        unless breaker.allow_request?
          raise ServiceUnavailableError.new("Circuit breaker open for service '#{@name}'")
        end
      end

      begin
        # Get or create client
        client = get_client

        # Build request with timeout
        request = build_request(method, params, headers)

        # Execute with retry policy
        response = execute_with_retry(client, request)

        # Record success
        @circuit_breaker.try(&.record_success)

        # Parse response
        parse_response(response)
      rescue ex : IO::TimeoutError
        @circuit_breaker.try(&.record_failure)
        raise ServiceTimeoutError.new("Service '#{@name}' timed out")
      rescue ex
        @circuit_breaker.try(&.record_failure)
        raise ServiceError.new("Service '#{@name}' error: #{ex.message}")
      end
    end

    # Perform health check on the service
    def health_check : HealthStatus
      # Try to call a health endpoint or ping
      # This is simplified - real implementation would use actual health endpoint
      @healthy = true
      @last_health_check = Time.utc

      HealthStatus.new(
        healthy: true,
        last_check: @last_health_check
      )
    rescue ex
      @healthy = false
      @last_health_check = Time.utc

      HealthStatus.new(
        healthy: false,
        last_check: @last_health_check,
        error: ex.message
      )
    end

    # Close the proxy and cleanup resources
    def close
      @client.try(&.close)
    end

    private def setup_client
      # Create HTTP transport and prefer discovery-aware client when registry is available
      transport_options = Core::Transport::Options.new
      transport = Stdlib::Transports::HTTPTransport.new(transport_options)
      @client = if reg = @registry
                  Stdlib::DiscoveryClient.new(transport, reg, Micro::Core::RoundRobinSelector.new)
                else
                  Stdlib::Client.new(transport)
                end
    rescue ex
      Log.warn { "Failed to create client for service '#{@name}': #{ex.message}" }
    end

    private def setup_circuit_breaker
      if config = @config.circuit_breaker
        @circuit_breaker = CircuitBreaker.new(
          failure_threshold: config.failure_threshold,
          success_threshold: config.success_threshold,
          timeout: config.timeout,
          half_open_requests: config.half_open_requests
        )
      end
    end

    private def get_client : Stdlib::Client
      @client || raise ServiceUnavailableError.new("No client available for service '#{@name}'")
    end

    private def build_request(method : String, params : JSON::Any, headers : HTTP::Headers?) : Core::TransportRequest
      endpoint = method.starts_with?("/") ? method : "/#{method}"
      # Forward selected headers (auth, request id) to the backend service
      fwd_headers = HTTP::Headers.new
      fwd_headers["Content-Type"] = "application/json"
      if incoming = headers
        if auth = incoming["Authorization"]?
          fwd_headers["Authorization"] = auth
        end
        if rid = incoming["X-Request-Id"]?
          fwd_headers["X-Request-Id"] = rid
        end
      end
      Core::TransportRequest.new(
        service: @name,
        method: endpoint,
        body: params.to_json.to_slice,
        content_type: "application/json",
        headers: fwd_headers
      )
    end

    private def execute_with_retry(client : Stdlib::Client, request : Core::TransportRequest) : Core::TransportResponse
      policy = @config.retry_policy || RetryPolicy.new

      attempt = 0
      backoff = policy.backoff

      loop do
        attempt += 1

        begin
          return client.call(request)
        rescue ex
          # Check if retryable
          # For now, we'll check common retryable errors
          retryable = ex.is_a?(IO::TimeoutError) || ex.is_a?(IO::Error)

          if !retryable || attempt >= policy.max_attempts
            raise ex
          end

          # Calculate backoff
          sleep_time = [backoff, policy.max_backoff].min
          Log.warn { "Retry attempt #{attempt} for service '#{@name}' after #{sleep_time}" }

          sleep sleep_time

          # Exponential backoff
          backoff = Time::Span.new(
            nanoseconds: (backoff.total_nanoseconds * policy.backoff_multiplier).to_i64
          )
        end
      end
    end

    private def parse_response(response : Core::TransportResponse) : JSON::Any
      body_string = String.new(response.body)
      JSON.parse(body_string)
    rescue ex : JSON::ParseException
      raise ServiceError.new("Invalid response from service '#{@name}': #{ex.message}")
    end
  end

  # Circuit breaker implementation
  class CircuitBreaker
    enum State
      Closed
      Open
      HalfOpen
    end

    getter state : State
    getter failure_count : Int32
    getter success_count : Int32
    getter last_failure_time : Time?
    getter half_open_requests : Int32

    def initialize(
      @failure_threshold : Int32 = 5,
      @success_threshold : Int32 = 2,
      @timeout : Time::Span = 30.seconds,
      @half_open_requests : Int32 = 3,
    )
      @state = State::Closed
      @failure_count = 0
      @success_count = 0
      @last_failure_time = nil
      @half_open_request_count = 0
      @mutex = Mutex.new
    end

    def allow_request? : Bool
      @mutex.synchronize do
        case @state
        when .closed?
          true
        when .open?
          # Check if timeout has passed
          if last_failure = @last_failure_time
            if Time.utc - last_failure > @timeout
              transition_to_half_open
              true
            else
              false
            end
          else
            false
          end
        when .half_open?
          # Allow limited requests in half-open state
          @half_open_request_count < @half_open_requests
        else
          false
        end
      end
    end

    def record_success
      @mutex.synchronize do
        case @state
        when .half_open?
          @success_count += 1
          if @success_count >= @success_threshold
            transition_to_closed
          end
        when .closed?
          @failure_count = 0
        end
      end
    end

    def record_failure
      @mutex.synchronize do
        @last_failure_time = Time.utc

        case @state
        when .closed?
          @failure_count += 1
          if @failure_count >= @failure_threshold
            transition_to_open
          end
        when .half_open?
          transition_to_open
        end
      end
    end

    private def transition_to_open
      @state = State::Open
      @success_count = 0
      @half_open_request_count = 0
      Log.warn { "Circuit breaker opened" }
    end

    private def transition_to_closed
      @state = State::Closed
      @failure_count = 0
      @success_count = 0
      @half_open_request_count = 0
      Log.info { "Circuit breaker closed" }
    end

    private def transition_to_half_open
      @state = State::HalfOpen
      @success_count = 0
      @failure_count = 0
      @half_open_request_count = 0
      Log.info { "Circuit breaker half-open" }
    end
  end

  # Service proxy exceptions
  class ServiceError < Exception; end

  class ServiceTimeoutError < ServiceError; end

  class MethodNotAllowedError < Exception; end
end
