require "../../core/middleware"
require "../../core/context"

module Micro::Stdlib::Middleware
  # Measures and reports request processing time.
  #
  # This lightweight middleware tracks how long requests take to process and
  # adds the duration to response headers. It's useful for performance monitoring
  # and debugging slow requests.
  #
  # ## Features
  # - Measures total request processing time
  # - Adds timing header to all responses (even errors)
  # - Stores timing in context for other middleware
  # - Precise to 2 decimal places (milliseconds)
  # - Minimal performance overhead
  #
  # ## Usage
  # ```
  # # Default header name (X-Response-Time)
  # server.use(TimingMiddleware.new)
  #
  # # Custom header name
  # server.use(TimingMiddleware.new("X-Server-Time"))
  # ```
  #
  # ## Response Headers
  # ```
  # X-Response-Time: 45.23ms
  # ```
  #
  # ## Context Attributes
  # The middleware stores the response time in milliseconds as a Float64:
  # ```
  # response_time_ms = context.get("response_time_ms", Float64)
  # ```
  #
  # ## Notes
  # - Uses monotonic time for accuracy across system time changes
  # - The timing includes all downstream middleware and handler execution
  # - Place early in the chain to measure total request time
  class TimingMiddleware
    include Micro::Core::Middleware

    def initialize(@header_name : String = "X-Response-Time")
    end

    def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
      start_time = Time.monotonic

      begin
        # Continue chain
        next_middleware.try(&.call(context))
      ensure
        # Always add timing header, even if an error occurred
        duration = Time.monotonic - start_time
        context.response.headers[@header_name] = "#{duration.total_milliseconds.round(2)}ms"

        # Store timing in context for other middleware
        context.set("response_time_ms", duration.total_milliseconds)
      end
    end
  end
end
