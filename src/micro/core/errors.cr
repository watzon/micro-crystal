require "socket"
require "json"
require "log"
require "http/client"
require "msgpack"
require "./transport"
require "./codec"
require "./broker"
require "./registry"
require "./pool"
require "../macros/error_handling"

module Micro
  module Core
    # Forward declarations not needed - we'll require the actual modules

    # Provides standardized error handling patterns for the microservice framework.
    # This module centralizes error classification, conversion, and handling utilities.
    module Errors
      # Classifies whether an error is retryable based on its type and characteristics.
      # Retryable errors are typically transient network or resource issues.
      def self.retryable?(error : Exception) : Bool
        case error
        when IO::TimeoutError,
             ::IO::Error,
             ::Socket::ConnectError,
             ::Socket::Error,
             ::Socket::Addrinfo::Error
          true
        when TransportError
          # Check error code for retryable transport errors
          case error.code
          when ErrorCode::ConnectionRefused,
               ErrorCode::ConnectionReset,
               ErrorCode::Timeout,
               ErrorCode::NetworkUnreachable
            true
          else
            false
          end
        when Broker::ConnectionError
          # Connection errors to brokers are typically retryable
          true
        when Registry::ConnectionError
          # Registry connection issues are retryable
          true
        when HTTP::Client::Response
          # Retry on specific HTTP status codes
          case error.status_code
          when 408, # Request Timeout
               429, # Too Many Requests
               502, # Bad Gateway
               503, # Service Unavailable
               504  # Gateway Timeout
            true
          else
            false
          end
          # Note: Pool errors handled by class name check below
        when ClientError
          # Client errors (4xx) are generally not retryable
          # except for specific cases like rate limiting
          error.is_a?(RateLimitError)
        else
          # Check by class name for pool errors to avoid circular dependencies
          class_name = error.class.name
          class_name.includes?("PoolTimeoutError") || class_name.includes?("PoolExhaustedError")
        end
      end

      # Classifies whether an error is permanent (non-retryable).
      def self.permanent?(error : Exception) : Bool
        !retryable?(error)
      end

      # Converts a generic exception to a transport error with appropriate error code.
      def self.to_transport_error(error : Exception | Errno, context : String? = nil) : TransportError
        case error
        when TransportError
          error
        when IO::TimeoutError
          TransportError.new(
            context ? "#{context}: #{error.message}" : error.message || "Operation timed out",
            ErrorCode::Timeout
          )
        when Errno
          TransportError.new(
            context ? "#{context}: #{error.message}" : error.message || "Connection failed",
            ErrorCode::ConnectionRefused
          )
        when IO::Error
          TransportError.new(
            context ? "#{context}: #{error.message}" : error.message || "IO error",
            ErrorCode::Unknown
          )
        else
          TransportError.new(
            context ? "#{context}: #{error.message}" : error.message || error.class.name,
            ErrorCode::Unknown
          )
        end
      end

      # Converts an exception to a codec error with appropriate error code.
      def self.to_codec_error(error : Exception, content_type : String? = nil) : CodecError
        case error
        when CodecError
          error
        when ::JSON::ParseException
          CodecError.new(
            "Failed to parse JSON: #{error.message}",
            CodecErrorCode::UnmarshalError,
            content_type
          )
        when ::JSON::SerializableError
          CodecError.new(
            "Failed to unmarshal JSON: #{error.message}",
            CodecErrorCode::TypeMismatch,
            content_type
          )
        when ::MessagePack::UnpackError
          CodecError.new(
            "Failed to parse MessagePack: #{error.message}",
            CodecErrorCode::UnmarshalError,
            content_type
          )
        when ArgumentError
          CodecError.new(
            "Invalid argument: #{error.message}",
            CodecErrorCode::TypeMismatch,
            content_type
          )
        else
          CodecError.new(
            "Codec error: #{error.message || error.class.name}",
            CodecErrorCode::UnmarshalError,
            content_type
          )
        end
      end

      # Wraps an error with additional context while preserving the original error type.
      def self.wrap(error : Exception, context : String) : Exception
        case error
        when TransportError
          TransportError.new("#{context}: #{error.message}", error.code)
        when CodecError
          CodecError.new("#{context}: #{error.message}", error.code, error.content_type)
        when ClientError
          # Preserve the specific client error type
          error.class.new("#{context}: #{error.message}")
        when ServerError
          # Preserve the specific server error type
          error.class.new("#{context}: #{error.message}")
        else
          # For generic exceptions, create a new one with context
          Exception.new("#{context}: #{error.message || error.class.name}")
        end
      end

      # Creates an error boundary that catches and handles errors in async operations.
      # This prevents errors from crashing background fibers.
      def self.boundary(operation_name : String, &) : Nil
        yield
      rescue ex : Exception
        Log.error(exception: ex) { "Error in #{operation_name}: #{ex.message}" }
      end

      # Creates an error boundary that returns a result or nil on error.
      def self.boundary_with_result(operation_name : String, & : -> T) : T? forall T
        yield
      rescue ex : Exception
        Log.error(exception: ex) { "Error in #{operation_name}: #{ex.message}" }
        nil
      end

      # Creates an error boundary that returns a result or default value on error.
      def self.boundary_with_default(operation_name : String, default : T, & : -> T) : T forall T
        yield
      rescue ex : Exception
        Log.error(exception: ex) { "Error in #{operation_name}: #{ex.message}" }
        default
      end

      # Extracts the root cause from a chain of wrapped exceptions.
      def self.root_cause(error : Exception) : Exception
        current = error

        # Follow the cause chain if available
        while cause = current.cause
          current = cause
        end

        current
      end

      # Determines if an error indicates a connection issue.
      def self.connection_error?(error : Exception | Errno) : Bool
        case error
        when Errno,
             IO::Error,
             TransportError,
             Broker::ConnectionError,
             Registry::ConnectionError
          true
        when HTTP::Client::Response
          # Connection errors manifest as specific status codes
          case error.status_code
          when 502, 503, 504
            true
          else
            false
          end
        else
          false
        end
      end

      # Determines if an error indicates a timeout.
      def self.timeout_error?(error : Exception) : Bool
        case error
        when ::IO::TimeoutError
          true
        when TransportError
          error.code == ErrorCode::Timeout
        when ::HTTP::Client::Response
          error.status_code == 408 || error.status_code == 504
        else
          # Check by class name for timeout errors to avoid circular dependencies
          error.class.name.includes?("TimeoutError") || error.class.name.includes?("PoolTimeoutError")
        end
      end

      # Logs an error with appropriate severity based on its type.
      def self.log_error(error : Exception, context : String? = nil)
        severity = case error
                   when ClientError
                     # Client errors are typically warnings (user error)
                     Log::Severity::Warn
                   when ServerError, TransportError, CodecError
                     # Server/infrastructure errors are errors
                     Log::Severity::Error
                   else
                     # Unknown errors default to error level
                     Log::Severity::Error
                   end

        message = context ? "#{context}: #{error.message}" : error.message || error.class.name

        case severity
        when Log::Severity::Warn
          Log.warn(exception: error) { message }
        when Log::Severity::Error
          Log.error(exception: error) { message }
        else
          Log.info(exception: error) { message }
        end
      end

      # Retry configuration for operations
      struct RetryConfig
        getter max_attempts : Int32
        getter base_delay : Time::Span
        getter max_delay : Time::Span
        getter exponential_base : Float64

        def initialize(
          @max_attempts : Int32 = 3,
          @base_delay : Time::Span = 100.milliseconds,
          @max_delay : Time::Span = 10.seconds,
          @exponential_base : Float64 = 2.0,
        )
        end

        # Calculate delay for a given attempt number (1-based)
        def delay_for_attempt(attempt : Int32) : Time::Span
          return Time::Span.zero if attempt <= 0

          # Exponential backoff with jitter
          delay = base_delay.total_seconds * (exponential_base ** (attempt - 1))
          delay = Math.min(delay, max_delay.total_seconds)

          # Add jitter (±20%)
          jitter = delay * (0.8 + Random.rand(0.4))
          Time::Span.new(seconds: jitter.to_i, nanoseconds: ((jitter % 1) * 1_000_000_000).to_i)
        end
      end

      # Performs an operation with automatic retry on retryable errors.
      def self.with_retry(operation_name : String, config : RetryConfig = RetryConfig.new, & : -> T) : T forall T
        last_error = nil

        config.max_attempts.times do |i|
          attempt = i + 1

          begin
            return yield
          rescue ex : Exception
            last_error = ex

            # Don't retry non-retryable errors
            unless retryable?(ex)
              log_error(ex, "#{operation_name} failed with permanent error")
              raise ex
            end

            # Don't retry if this was the last attempt
            if attempt >= config.max_attempts
              log_error(ex, "#{operation_name} failed after #{attempt} attempts")
              raise ex
            end

            # Calculate and apply delay
            delay = config.delay_for_attempt(attempt)
            Log.debug { "#{operation_name} failed (attempt #{attempt}/#{config.max_attempts}), retrying in #{delay.total_seconds}s: #{ex.message}" }
            sleep delay
          end
        end

        # This should never be reached, but just in case
        raise last_error || Exception.new("Retry logic error")
      end
    end
  end
end
