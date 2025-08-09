require "uuid"

module Micro::Core
  # ConnectionPool manages a pool of reusable transport sockets
  # to reduce connection overhead and improve performance
  abstract class ConnectionPool
    # Pool configuration options
    struct Config
      # Maximum number of connections in the pool
      property max_size : Int32

      # Maximum idle connections to keep open
      property max_idle : Int32

      # Timeout for acquiring a connection from the pool
      property acquire_timeout : Time::Span

      # How long a connection can be idle before being closed
      property idle_timeout : Time::Span

      # Maximum lifetime of a connection before forced refresh
      property max_lifetime : Time::Span

      # Time to wait between connection health checks
      property health_check_interval : Time::Span

      # Whether to perform health checks on idle connections
      property health_check_enabled : Bool

      def initialize(
        @max_size : Int32 = 10,
        @max_idle : Int32 = 5,
        @acquire_timeout : Time::Span = 5.seconds,
        @idle_timeout : Time::Span = 5.minutes,
        @max_lifetime : Time::Span = 1.hour,
        @health_check_interval : Time::Span = 30.seconds,
        @health_check_enabled : Bool = true,
      )
        raise ArgumentError.new("max_size must be positive") unless @max_size > 0
        raise ArgumentError.new("max_idle cannot exceed max_size") if @max_idle > @max_size
      end
    end

    # Connection wrapper with metadata
    class PooledConnection
      # The actual transport socket
      getter socket : Socket

      # When the connection was created
      getter created_at : Time

      # When the connection was last used
      property last_used_at : Time

      # Number of times this connection has been used
      property use_count : Int32

      # Whether this connection is currently in use
      property? in_use : Bool

      # Unique identifier for tracking
      getter id : String

      def initialize(@socket : Socket)
        @created_at = Time.utc
        @last_used_at = Time.utc
        @use_count = 0
        @in_use = false
        @id = UUID.random.to_s
      end

      # Check if connection has exceeded its lifetime
      def expired?(max_lifetime : Time::Span) : Bool
        Time.utc - @created_at > max_lifetime
      end

      # Check if connection has been idle too long
      def idle_expired?(idle_timeout : Time::Span) : Bool
        !in_use? && (Time.utc - @last_used_at > idle_timeout)
      end

      # Mark connection as being used
      def acquire : Nil
        @in_use = true
        @use_count += 1
        @last_used_at = Time.utc
      end

      # Mark connection as available
      def release : Nil
        @in_use = false
        @last_used_at = Time.utc
      end
    end

    # Pool statistics for monitoring
    struct Stats
      # Total connections currently in the pool
      property total_connections : Int32

      # Connections currently in use
      property active_connections : Int32

      # Idle connections available
      property idle_connections : Int32

      # Total successful acquisitions
      property total_acquired : Int64

      # Total acquisition timeouts
      property total_timeouts : Int64

      # Total connection errors
      property total_errors : Int64

      # Average wait time for acquisition (ms)
      property avg_wait_time_ms : Float64

      def initialize(
        @total_connections : Int32 = 0,
        @active_connections : Int32 = 0,
        @idle_connections : Int32 = 0,
        @total_acquired : Int64 = 0,
        @total_timeouts : Int64 = 0,
        @total_errors : Int64 = 0,
        @avg_wait_time_ms : Float64 = 0.0,
      )
      end
    end

    # Get pool configuration
    abstract def config : Config

    # Acquire a connection from the pool
    # Returns nil if timeout is reached
    abstract def acquire : PooledConnection?

    # Release a connection back to the pool
    # If the connection is unhealthy, it will be closed
    abstract def release(connection : PooledConnection) : Nil

    # Close all connections and shutdown the pool
    abstract def close : Nil

    # Check if the pool is closed
    abstract def closed? : Bool

    # Get current pool statistics
    abstract def stats : Stats

    # Perform health check on a connection
    # Returns true if healthy, false otherwise
    abstract def health_check(connection : PooledConnection) : Bool

    # Remove unhealthy or expired connections
    abstract def prune : Int32
  end

  # Factory for creating connections
  abstract class ConnectionFactory
    # Create a new connection
    abstract def create : Socket

    # Validate that a connection is still healthy
    abstract def validate(socket : Socket) : Bool
  end

  # Pool errors
  class PoolError < Exception
  end

  class PoolClosedError < PoolError
    def initialize
      super("Connection pool is closed")
    end
  end

  class PoolExhaustedError < PoolError
    def initialize(timeout : Time::Span)
      super("Failed to acquire connection within #{timeout.total_seconds}s")
    end
  end
end
