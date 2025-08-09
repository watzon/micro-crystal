require "../../core/middleware"
require "../../core/context"
require "log"

module Micro::Stdlib::Middleware
  # Catches and recovers from any unhandled exceptions to prevent server crashes.
  #
  # This middleware acts as a safety net, ensuring that even if an unexpected error
  # occurs, the server will continue running and return a generic error response
  # instead of crashing. It should typically be placed at the beginning of the
  # middleware chain.
  #
  # ## Features
  # - Catches all unhandled exceptions
  # - Logs errors with FATAL level including stack traces
  # - Returns generic 500 error without exposing internal details
  # - Includes request ID in error response for debugging
  # - Stores exception in context for other middleware to access
  #
  # ## Usage
  # ```
  # server.use(RecoveryMiddleware.new)
  #
  # # Or with custom logger
  # server.use(RecoveryMiddleware.new(Log.for("app.recovery")))
  # ```
  #
  # ## Response Format
  # ```json
  # {
  #   "error": "Internal server error",
  #   "request_id": "550e8400-e29b-41d4-a716-446655440000"
  # }
  # ```
  class RecoveryMiddleware
    include Micro::Core::Middleware

    def initialize(@log : Log = Log.for("micro.middleware.recovery"))
    end

    def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
      # Continue chain
      next_middleware.try(&.call(context))
    rescue ex : Exception
      # Log the panic
      request_id = context.get("request_id", String) || "unknown"
      @log.fatal(exception: ex) do
        "[#{request_id}] PANIC recovered in #{context.request.endpoint}: #{ex.message}"
      end

      # Set a generic error response
      context.response.status = 500
      context.response.headers["Content-Type"] = "application/json"

      # Don't expose internal details in recovery mode
      context.response.body = {
        "error"      => "Internal server error",
        "request_id" => request_id,
      }

      # Store error in context
      context.error = ex

      # Don't re-raise - this middleware's job is to prevent crashes
    end
  end
end
