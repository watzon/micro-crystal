# Error handling and status code mapping for micro-crystal framework
# These macros enhance error handling in RPC methods

module Micro::Macros
  # Module that provides enhanced error handling for RPC methods
  module ErrorHandling
    # Standard error to status code mappings
    ERROR_STATUS_MAPPINGS = {
      "ArgumentError"                        => 400,
      "KeyError"                             => 400,
      "JSON::ParseException"                 => 400,
      "Micro::Core::CodecError"              => 400,
      "Micro::Core::NotFoundError"           => 404,
      "Micro::Core::UnauthorizedError"       => 401,
      "Micro::Core::ForbiddenError"          => 403,
      "Micro::Core::ConflictError"           => 409,
      "Micro::Core::ValidationError"         => 422,
      "Micro::Core::RateLimitError"          => 429,
      "Micro::Core::ServiceUnavailableError" => 503,
      "IO::TimeoutError"                     => 504,
    }

    # Map an error to appropriate HTTP status code
    def self.status_for_error(error : Exception) : Int32
      # Check exact type matches first
      ERROR_STATUS_MAPPINGS[error.class.name]? ||
        # Check if it's a client error with embedded status
        (error.responds_to?(:status_code) ? error.status_code : 500)
    end

    # Format error response based on error type
    def self.format_error_response(error : Exception) : Hash(String, String)
      response = {} of String => String
      response["error"] = error.message || error.class.name
      response["type"] = error.class.name

      # Add additional fields for specific error types
      case error
      when Micro::Core::ValidationError
        if error.responds_to?(:validation_errors) && (errors = error.validation_errors)
          # Convert validation errors to JSON string
          response["validation_errors"] = errors.to_json
        end
      when Micro::Core::RateLimitError
        if error.responds_to?(:retry_after) && (retry_after = error.retry_after)
          response["retry_after"] = retry_after.to_s
        end
      end

      response
    end

    # Macro to wrap method execution with error handling
    macro with_error_handling(context)
      begin
        {{yield}}
      rescue ex : ::Micro::Core::CodecError
        {{context}}.response.status = 400
        {{context}}.response.body = {"error" => "Invalid request format: #{ex.message}", "type" => ex.class.name}
      rescue ex : ArgumentError, KeyError
        {{context}}.response.status = 400
        {{context}}.response.body = {"error" => ex.message || "Bad request", "type" => ex.class.name}
      rescue ex : Exception
        # Use error mapping
        {{context}}.response.status = ::Micro::Macros::ErrorHandling.status_for_error(ex)
        {{context}}.response.body = ::Micro::Macros::ErrorHandling.format_error_response(ex)

        # Log error for 5xx errors
        if {{context}}.response.status >= 500
          Log.error(exception: ex) { "Internal error in #{{{context}}.request.endpoint}" }
        end
      end
    end
  end
end

# Define standard error types that services can use
module Micro::Core
  # Base class for client errors (4xx)
  class ClientError < Exception
    getter status_code : Int32

    def initialize(@message : String? = nil, @status_code : Int32 = 400)
      super(@message)
    end
  end

  # Specific error types
  class NotFoundError < ClientError
    def initialize(message : String? = "Not found")
      super(message, 404)
    end
  end

  class UnauthorizedError < ClientError
    def initialize(message : String? = "Unauthorized")
      super(message, 401)
    end
  end

  class ForbiddenError < ClientError
    def initialize(message : String? = "Forbidden")
      super(message, 403)
    end
  end

  class ConflictError < ClientError
    def initialize(message : String? = "Conflict")
      super(message, 409)
    end
  end

  class ValidationError < ClientError
    getter validation_errors : Hash(String, Array(String))?

    def initialize(message : String? = "Validation failed", @validation_errors : Hash(String, Array(String))? = nil)
      super(message, 422)
    end
  end

  class RateLimitError < ClientError
    getter retry_after : Int32?

    def initialize(message : String? = "Rate limit exceeded", @retry_after : Int32? = nil)
      super(message, 429)
    end
  end

  # Base class for server errors (5xx)
  class ServerError < Exception
    getter status_code : Int32

    def initialize(@message : String? = nil, @status_code : Int32 = 500)
      super(@message)
    end
  end

  class ServiceUnavailableError < ServerError
    def initialize(message : String? = "Service unavailable")
      super(message, 503)
    end
  end
end
