require "../../core/middleware"
require "../../core/context"

module Micro::Stdlib::Middleware
  # Enforces time limits on request processing to prevent hung requests.
  #
  # This middleware ensures that requests complete within a specified time limit,
  # protecting against slow handlers, deadlocks, or unresponsive external services.
  # It uses Crystal's fiber and channel system for efficient timeout handling.
  #
  # ## Features
  # - Configurable timeout duration
  # - Graceful timeout handling with proper error response
  # - Preserves original exceptions if they occur
  # - Uses lightweight fibers (no thread overhead)
  # - Returns standard 504 Gateway Timeout status
  #
  # ## Usage
  # ```
  # # 30 second timeout
  # server.use(TimeoutMiddleware.new(30.seconds))
  #
  # # 5 second timeout with custom message
  # server.use(TimeoutMiddleware.new(
  #   timeout: 5.seconds,
  #   error_message: "Operation took too long"
  # ))
  #
  # # Different timeouts for different endpoints
  # @[Micro::Middleware(
  #   names: ["timeout"],
  #   options: {"timeout" => {"seconds" => 60}}
  # )]
  # def slow_operation
  #   # ...
  # end
  # ```
  #
  # ## Response Format
  # On timeout, returns 504 with:
  # ```json
  # {
  #   "error": "Request timeout",
  #   "timeout": 30.0
  # }
  # ```
  #
  # ## Important Notes
  # - The timeout applies to the entire downstream chain
  # - Timed-out requests may continue executing in background
  # - Cannot cancel Crystal fibers mid-execution
  # - Set context.error to TimeoutError for tracking
  #
  # ## Placement
  # Place this middleware after logging/metrics middleware so timeouts
  # are properly tracked, but before expensive operations.
  class TimeoutMiddleware
    include Micro::Core::Middleware

    def initialize(
      @timeout : Time::Span,
      @error_message : String = "Request timeout",
    )
    end

    def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
      # Create a channel for completion signal
      done = Channel(Nil).new
      exception = Channel(Exception).new

      # Run the handler in a fiber
      spawn do
        begin
          next_middleware.try(&.call(context))
          begin
            done.send(nil)
          rescue Channel::ClosedError
            # Timeout branch closed channel; ignore
          end
        rescue ex
          begin
            exception.send(ex)
          rescue Channel::ClosedError
            # Timeout branch closed channel; ignore
          end
        end
      end

      begin
        # Wait for completion or timeout
        select
        when done.receive
          # Completed successfully
        when ex = exception.receive
          # Exception occurred, re-raise it
          raise ex
        when timeout(@timeout)
          # Timeout occurred
          handle_timeout(context)
        end
      ensure
        # Clean up channels
        done.close rescue nil
        exception.close rescue nil
      end
    end

    private def handle_timeout(context : Micro::Core::Context) : Nil
      context.response.status = 504 # Gateway Timeout
      context.response.body = {
        "error"   => @error_message,
        "timeout" => @timeout.total_seconds.to_s,
      }

      # Set timeout error in context
      context.error = TimeoutError.new(@error_message)
    end
  end

  # Custom timeout error
  class TimeoutError < Exception
  end
end
