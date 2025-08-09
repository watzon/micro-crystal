module Micro::Core
  # Strategy for performing health checks on connections
  abstract class HealthCheckStrategy
    # Perform a health check on a socket
    # Returns true if healthy, false otherwise
    abstract def check(socket : Socket) : Bool

    # Get a description of this health check strategy
    abstract def description : String
  end

  # Configuration for health check behavior
  struct HealthCheckConfig
    # Maximum attempts before considering unhealthy
    property max_attempts : Int32

    # Delay between retry attempts
    property retry_delay : Time::Span

    # Timeout for each health check attempt
    property check_timeout : Time::Span

    # Whether to refresh connection on health check failure
    property refresh_on_failure : Bool

    def initialize(
      @max_attempts : Int32 = 3,
      @retry_delay : Time::Span = 100.milliseconds,
      @check_timeout : Time::Span = 2.seconds,
      @refresh_on_failure : Bool = true,
    )
      raise ArgumentError.new("max_attempts must be positive") unless @max_attempts > 0
    end
  end

  # Result of a health check operation
  struct HealthCheckResult
    # Whether the check passed
    getter? healthy : Bool

    # Number of attempts made
    getter attempts : Int32

    # Total time taken
    getter duration : Time::Span

    # Error message if unhealthy
    getter error : String?

    # Whether connection was refreshed
    getter? refreshed : Bool

    def initialize(@healthy : Bool, @attempts : Int32, @duration : Time::Span, @error : String? = nil, @refreshed : Bool = false)
    end
  end

  # Basic health check that just verifies socket is open
  class BasicHealthCheck < HealthCheckStrategy
    def check(socket : Socket) : Bool
      !socket.closed?
    end

    def description : String
      "Basic socket open check"
    end
  end

  # No-op health check (always passes)
  class NoOpHealthCheck < HealthCheckStrategy
    def check(socket : Socket) : Bool
      true
    end

    def description : String
      "No-op (always healthy)"
    end
  end
end
