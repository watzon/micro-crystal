require "./health_check"
require "./pool"
require "log"

module Micro::Core
  # Executes health checks with retry logic and connection refresh
  class HealthCheckExecutor
    getter config : HealthCheckConfig
    getter strategy : HealthCheckStrategy
    getter factory : ConnectionFactory?

    Log = ::Log.for("micro.health_check")

    def initialize(@config : HealthCheckConfig, @strategy : HealthCheckStrategy, @factory : ConnectionFactory? = nil)
    end

    # Execute health check on a pooled connection with retry logic
    def execute(connection : ConnectionPool::PooledConnection) : HealthCheckResult
      start_time = Time.utc
      attempts = 0
      last_error : String? = nil
      refreshed = false

      loop do
        attempts += 1

        begin
          # Perform the health check
          healthy = @strategy.check(connection.socket)

          if healthy
            # Success!
            duration = Time.utc - start_time
            return HealthCheckResult.new(
              healthy: true,
              attempts: attempts,
              duration: duration,
              refreshed: refreshed
            )
          else
            last_error = "Health check failed: #{@strategy.description}"
            Log.debug { "Health check attempt #{attempts} failed for connection #{connection.id}" }
          end
        rescue ex
          last_error = "Health check error: #{ex.message}"
          Log.debug { "Health check attempt #{attempts} error for connection #{connection.id}: #{ex.message}" }
        end

        # Check if we should retry
        if attempts >= @config.max_attempts
          break
        end

        # Wait before retry
        sleep @config.retry_delay

        # Try to refresh connection if configured and we have a factory
        if @config.refresh_on_failure && @factory && attempts == @config.max_attempts - 1
          if refresh_connection(connection)
            refreshed = true
            Log.info { "Refreshed connection #{connection.id} after health check failures" }
          else
            Log.warn { "Failed to refresh connection #{connection.id}" }
            break
          end
        end
      end

      # All attempts failed
      duration = Time.utc - start_time
      HealthCheckResult.new(
        healthy: false,
        attempts: attempts,
        duration: duration,
        error: last_error,
        refreshed: refreshed
      )
    end

    # Execute health check on a raw socket (simpler version)
    def execute_simple(socket : Socket) : Bool
      attempts = 0

      loop do
        attempts += 1

        begin
          if @strategy.check(socket)
            return true
          end
        rescue
          # Ignore errors, treat as unhealthy
        end

        if attempts >= @config.max_attempts
          return false
        end

        sleep @config.retry_delay
      end
    end

    private def refresh_connection(connection : ConnectionPool::PooledConnection) : Bool
      # Connection refresh is not directly supported in current design
      # The pool should handle creating new connections when needed
      # Return false to indicate the connection should be removed from pool
      false
    end
  end

  # Mixin for pools that support health checking
  module HealthCheckable
    # Get or set the health check executor
    abstract def health_check_executor : HealthCheckExecutor
    abstract def health_check_executor=(health_check_executor : HealthCheckExecutor)

    # Perform health check with retry and refresh
    def health_check_with_retry(connection : ConnectionPool::PooledConnection) : HealthCheckResult
      health_check_executor.execute(connection)
    end

    # Simple health check on socket
    def validate_socket(socket : Socket) : Bool
      health_check_executor.execute_simple(socket)
    end
  end
end
