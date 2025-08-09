module Micro::Core
  # Provides consistent error message formatting across the framework
  module ErrorFormatter
    # Formats an error message with consistent structure
    #
    # Format: "Failed to [action]: [reason] ([context])"
    # Example: "Failed to connect: connection refused (address: localhost:8080)"
    def self.format(action : String, reason : String, context : Hash(String, String)? = nil) : String
      message = "Failed to #{action}: #{reason}"

      if context && !context.empty?
        context_str = context.map { |k, v| "#{k}: #{v}" }.join(", ")
        message += " (#{context_str})"
      end

      message
    end

    # Formats a validation error message
    #
    # Format: "Validation failed: [field] [issue]"
    # Example: "Validation failed: max_size must be positive"
    def self.validation(field : String, issue : String) : String
      "Validation failed: #{field} #{issue}"
    end

    # Formats a configuration error message
    #
    # Format: "Configuration error: [issue] ([detail])"
    # Example: "Configuration error: missing required field (field: api_key)"
    def self.config(issue : String, detail : String? = nil) : String
      message = "Configuration error: #{issue}"
      message += " (#{detail})" if detail
      message
    end

    # Formats a timeout error message
    #
    # Format: "Operation timed out: [operation] after [duration]"
    # Example: "Operation timed out: connection attempt after 5s"
    def self.timeout(operation : String, duration : Time::Span) : String
      "Operation timed out: #{operation} after #{duration.total_seconds}s"
    end

    # Formats a not found error message
    #
    # Format: "Not found: [resource] [identifier]"
    # Example: "Not found: service 'auth-service'"
    def self.not_found(resource : String, identifier : String) : String
      "Not found: #{resource} '#{identifier}'"
    end

    # Formats a connection error message
    #
    # Format: "Connection failed: [reason] (target: [address])"
    # Example: "Connection failed: connection refused (target: localhost:8080)"
    def self.connection(reason : String, address : String) : String
      format("connect", reason, {"target" => address})
    end

    # Formats a parsing error message
    #
    # Format: "Failed to parse [type]: [reason] ([location])"
    # Example: "Failed to parse JSON: unexpected token (line: 5, column: 12)"
    def self.parse(type : String, reason : String, location : Hash(String, String)? = nil) : String
      format("parse #{type}", reason, location)
    end
  end
end
