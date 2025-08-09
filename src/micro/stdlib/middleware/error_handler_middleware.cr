require "../../core/middleware"
require "../../core/context"
require "log"

module Micro::Stdlib::Middleware
  # Catches exceptions and returns properly formatted error responses.
  #
  # Unlike RecoveryMiddleware which provides a generic response, this middleware
  # formats errors with details appropriate for the environment. It can show
  # stack traces in development and maps exceptions to appropriate HTTP status codes.
  #
  # ## Features
  # - Maps exception types to HTTP status codes
  # - Optionally includes stack traces (for development)
  # - Logs errors with full exception details
  # - Returns structured JSON error responses
  # - Stores exception in context for downstream access
  #
  # ## Status Code Mapping
  # - `ArgumentError` → 400 Bad Request
  # - `KeyError`, `IndexError` → 404 Not Found
  # - All others → 500 Internal Server Error
  #
  # ## Usage
  # ```
  # # Production mode (no stack traces)
  # server.use(ErrorHandlerMiddleware.new)
  #
  # # Development mode (with stack traces)
  # server.use(ErrorHandlerMiddleware.new(show_details: true))
  #
  # # Custom logger
  # server.use(ErrorHandlerMiddleware.new(
  #   log: Log.for("app.errors"),
  #   show_details: ENV["CRYSTAL_ENV"] == "development"
  # ))
  # ```
  #
  # ## Response Format
  # ```json
  # {
  #   "error": "User not found",
  #   "type": "KeyError",
  #   "request_id": "550e8400-e29b-41d4-a716-446655440000",
  #   "backtrace": [...]  // Only if show_details is true
  # }
  # ```
  class ErrorHandlerMiddleware
    include Micro::Core::Middleware

    def initialize(
      @log : Log = Log.for("micro.middleware.error_handler"),
      @show_details : Bool = false,
    )
    end

    def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
      # Continue chain
      next_middleware.try(&.call(context))
    rescue ex : Exception
      # Log the error with full details
      request_id = context.get("request_id", String) || "unknown"
      @log.error(exception: ex) do
        "[#{request_id}] Unhandled exception in #{context.request.endpoint}: #{ex.message}"
      end

      # Set error response
      context.response.status = status_code_for(ex)

      error_body = {} of String => String | Array(String)
      error_body["error"] = ex.message || "Internal server error"
      error_body["type"] = ex.class.name

      # Add details in development/debug mode
      if @show_details && ex.responds_to?(:backtrace)
        error_body["backtrace"] = ex.backtrace? || [] of String
      end

      # Add request ID if available
      if request_id != "unknown"
        error_body["request_id"] = request_id
      end

      # Convert to JSON::Any to match Response type
      json_body = JSON.parse(error_body.to_json)
      context.response.body = json_body
      context.response.headers["Content-Type"] = "application/json"

      # Store error in context for other middleware
      context.error = ex
    end

    private def status_code_for(ex : Exception) : ::Int32
      case ex
      when ArgumentError
        400 # Bad Request
      when KeyError, IndexError
        404 # Not Found
      else
        500 # Internal Server Error
      end
    end
  end
end
