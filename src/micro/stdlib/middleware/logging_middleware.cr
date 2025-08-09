require "../../core/middleware"
require "../../core/context"
require "log"
require "uuid"

module Micro::Stdlib::Middleware
  # Logs request and response details with timing information.
  #
  # This middleware provides structured logging for all requests passing through
  # the server. It automatically generates request IDs if not present, tracks
  # request duration, and logs both successful and failed requests.
  #
  # ## Features
  # - Generates unique request IDs (if not already set)
  # - Logs request start with endpoint and service info
  # - Tracks request duration with millisecond precision
  # - Logs response status codes
  # - Captures and logs exceptions while re-raising them
  # - Adds `X-Request-ID` header to responses
  #
  # ## Usage
  # ```
  # # Default logger
  # server.use(LoggingMiddleware.new)
  #
  # # Custom logger
  # server.use(LoggingMiddleware.new(Log.for("app.requests")))
  # ```
  #
  # ## Log Format
  # ```
  # # Successful request
  # [550e8400-e29b-41d4-a716-446655440000] Started /users from api-service
  # [550e8400-e29b-41d4-a716-446655440000] Completed 200 in 45.23ms
  #
  # # Failed request
  # [550e8400-e29b-41d4-a716-446655440000] Started /users/999 from api-service
  # [550e8400-e29b-41d4-a716-446655440000] Failed with KeyError: User not found in 12.45ms
  # ```
  #
  # ## Integration
  # Works well with RequestIDMiddleware to ensure consistent request tracking
  # across all middleware and handlers.
  class LoggingMiddleware
    include Micro::Core::Middleware

    def initialize(@log : Log = Log.for("micro.middleware.logging"))
    end

    def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
      # Generate request ID if not already set
      request_id = if context.has?("request_id")
                     context.get!("request_id", String)
                   else
                     id = UUID.random.to_s
                     context.set("request_id", id)
                     id
                   end

      # Record start time
      start_time = Time.monotonic

      # Log request
      @log.info do
        "[#{request_id}] Started #{context.request.endpoint} " \
        "from #{context.request.service}"
      end

      # Add request ID to response headers
      context.response.headers["X-Request-ID"] = request_id

      begin
        # Continue chain
        next_middleware.try(&.call(context))

        # Log response
        duration = Time.monotonic - start_time
        @log.info do
          "[#{request_id}] Completed #{context.response.status} " \
          "in #{duration.total_milliseconds.round(2)}ms"
        end
      rescue ex
        # Log error
        duration = Time.monotonic - start_time
        @log.error do
          "[#{request_id}] Failed with #{ex.class.name}: #{ex.message} " \
          "in #{duration.total_milliseconds.round(2)}ms"
        end

        # Re-raise to let other middleware handle it
        raise ex
      end
    end
  end
end
