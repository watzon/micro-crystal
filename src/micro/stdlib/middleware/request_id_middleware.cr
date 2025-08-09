require "../../core/middleware"
require "../../core/context"
require "uuid"

module Micro::Stdlib::Middleware
  # Ensures every request has a unique identifier for tracing and correlation.
  #
  # This middleware generates or preserves request IDs, making it easier to track
  # requests across services and in logs. If a request already contains an ID,
  # it will be preserved (useful for distributed tracing).
  #
  # ## Features
  # - Generates UUID v4 request IDs by default
  # - Preserves existing request IDs from headers
  # - Stores ID in context for all middleware/handlers
  # - Optionally adds ID to response headers
  # - Supports custom ID generators
  #
  # ## Usage
  # ```
  # # Default configuration
  # server.use(RequestIDMiddleware.new)
  #
  # # Custom header name
  # server.use(RequestIDMiddleware.new("X-Trace-ID"))
  #
  # # Don't include in response
  # server.use(RequestIDMiddleware.new(response_header: false))
  #
  # # Custom ID generator
  # server.use(RequestIDMiddleware.new(
  #   generator: -> { "req-#{Time.utc.to_unix_ms}" }
  # ))
  # ```
  #
  # ## Headers
  # ```
  # # Request (optional)
  # X-Request-ID: 550e8400-e29b-41d4-a716-446655440000
  #
  # # Response (by default)
  # X-Request-ID: 550e8400-e29b-41d4-a716-446655440000
  # ```
  #
  # ## Context Access
  # ```
  # request_id = context.get("request_id", String)
  # ```
  #
  # ## Distributed Tracing
  # When used across multiple services, request IDs enable tracing requests
  # through your entire system. Services should forward the X-Request-ID header
  # when making downstream calls.
  class RequestIDMiddleware
    include Micro::Core::Middleware

    def initialize(
      @header_name : String = "X-Request-ID",
      @response_header : Bool = true,
      @generator : Proc(String)? = nil,
    )
    end

    def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
      # Check if request already has an ID
      request_id = context.request.headers[@header_name]?

      # Generate new ID if needed
      if request_id.nil? || request_id.empty?
        request_id = if gen = @generator
                       gen.call
                     else
                       UUID.random.to_s
                     end
      end

      # Store in context for other middleware/handlers
      context.set("request_id", request_id)

      # Add to response headers if configured
      if @response_header
        context.response.headers[@header_name] = request_id
      end

      # Continue chain
      next_middleware.try(&.call(context))
    end
  end
end
