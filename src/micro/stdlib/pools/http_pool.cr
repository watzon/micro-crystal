require "../../core/pool"
require "../../core/health_check_executor"
require "../../core/metrics"
require "../../core/closable_resource"
require "../../core/fiber_tracker"
require "../../core/error_formatter"
require "../transports/http"
require "../health_checks/http_health_check"
require "../metrics/prometheus_metrics"
require "log"

module Micro::Stdlib::Pools
  Log = ::Log.for("micro.pool")

  # HTTP-specific connection pool implementation
  # Based on Crystal's DB pool design patterns
  class HTTPConnectionPool < Micro::Core::ConnectionPool
    include Micro::Core::HealthCheckable
    include Micro::Core::MetricsCollectable
    include Micro::Core::ClosableResource
    include Micro::Core::FiberTracker

    getter config : Config
    property health_check_executor : Micro::Core::HealthCheckExecutor

    @connections : Array(PooledConnection)
    @idle : Set(PooledConnection)
    @factory : Micro::Core::ConnectionFactory
    @availability_channel : Channel(Nil)
    @inflight : Int32
    @mutex : Mutex
    @stats : Stats
    @enhanced_stats : Micro::Core::EnhancedPoolStats
    @metrics_collector : Micro::Core::MetricsCollector
    @metrics_config : Micro::Stdlib::Metrics::MetricsConfig
    @pruning_fiber : Fiber?
    @metrics_fiber : Fiber?

    def initialize(@config : Config, @factory : Micro::Core::ConnectionFactory, health_strategy : Micro::Core::HealthCheckStrategy? = nil, metrics_config : Micro::Stdlib::Metrics::MetricsConfig? = nil, metrics_collector : Micro::Core::MetricsCollector? = nil)
      @connections = [] of PooledConnection
      @idle = Set(PooledConnection).new
      @availability_channel = Channel(Nil).new
      @inflight = 0
      @mutex = Mutex.new
      @stats = Stats.new
      @enhanced_stats = Micro::Core::EnhancedPoolStats.new(
        max_size: @config.max_size,
        max_idle: @config.max_idle
      )
      @metrics_config = metrics_config || Micro::Stdlib::Metrics::MetricsConfig.new
      @metrics_collector = metrics_collector || Micro::Stdlib::Metrics::MetricsFactory.default_collector

      # Set up health check executor
      strategy = health_strategy || Micro::Stdlib::HealthChecks::HTTPHeadHealthCheck.new
      health_config = Micro::Core::HealthCheckConfig.new(
        max_attempts: 3,
        retry_delay: 200.milliseconds,
        check_timeout: 2.seconds,
        refresh_on_failure: true
      )
      @health_check_executor = Micro::Core::HealthCheckExecutor.new(health_config, strategy, @factory)

      # Start background pruning if enabled
      if @config.health_check_enabled
        start_pruning_fiber
      end

      # Start metrics reporting if enabled
      if @metrics_config.enabled
        start_metrics_fiber
      end
    end

    def acquire : PooledConnection?
      return nil if closed?

      start_time = Time.utc

      conn = sync do
        connection = nil
        attempts = 0
        max_attempts = @config.max_size

        until connection || attempts >= max_attempts
          connection = if @idle.empty?
                         if can_increase_pool?
                           @inflight += 1
                           begin
                             # Build connection outside of mutex
                             new_conn = unsync { create_connection }
                             if new_conn
                               @connections << new_conn
                               update_enhanced_stats
                               new_conn
                             else
                               # Creation failed, increment attempts
                               attempts += 1
                               nil
                             end
                           ensure
                             @inflight -= 1
                           end
                         else
                           # Wait for available connection
                           unsync { wait_for_available }
                           pick_available
                         end
                       else
                         pick_available
                       end
        end

        if connection
          @idle.delete(connection)
          connection.acquire
          update_enhanced_stats
          connection
        else
          nil
        end
      end

      update_acquire_stats(start_time) if conn
      conn
    rescue ex : PoolTimeoutError
      increment_timeouts
      nil
    end

    def release(connection : PooledConnection) : Nil
      return if closed?

      idle_pushed = false

      sync do
        connection.release

        if validate_connection(connection) && can_increase_idle?
          @idle << connection
          idle_pushed = true
        else
          remove_connection(connection)
        end

        update_enhanced_stats
      end

      # Notify waiting fibers if we added to idle pool
      if idle_pushed
        select
        when @availability_channel.send(nil)
        else
          # Channel full, no waiters
        end
      end
    end

    # Implement the perform_close method required by ClosableResource
    protected def perform_close : Nil
      Log.debug { "Closing HTTP connection pool" }

      sync do
        # Shutdown background fibers
        shutdown_fibers(5.seconds)

        # Close all connections
        @connections.each do |conn|
          begin
            conn.socket.close
          rescue ex : Exception
            Log.debug(exception: ex) { "Failed to close connection socket" }
          end
        end
        @connections.clear
        @idle.clear

        # Close channel
        begin
          @availability_channel.close
        rescue ex : Exception
          Log.debug(exception: ex) { "Failed to close availability channel" }
        end
      end

      Log.debug { "HTTP connection pool closed" }
    end

    def stats : Stats
      sync { @stats.dup }
    end

    def health_check(connection : PooledConnection) : Bool
      return false if connection.socket.closed?
      return false if connection.expired?(@config.max_lifetime)
      return false if connection.idle_expired?(@config.idle_timeout)

      start_time = Time.utc

      # Use health check executor with retry logic
      result = health_check_with_retry(connection)

      # Record metrics for health check
      record_health_check_metrics(start_time, result.healthy?)

      # Update stats based on result
      if result.healthy?
        Log.trace { "Connection #{connection.id} passed health check after #{result.attempts} attempts" }
      else
        Log.debug { "Connection #{connection.id} failed health check: #{result.error}" }
        @stats.total_errors += 1
      end

      result.healthy?
    end

    def prune : Int32
      pruned = 0
      to_remove = [] of PooledConnection

      sync do
        @idle.each do |conn|
          if !health_check(conn)
            to_remove << conn
            pruned += 1
          end
        end

        to_remove.each do |conn|
          @idle.delete(conn)
          remove_connection(conn)
        end

        if pruned > 0
          @enhanced_stats.total_pruned += pruned.to_i64
          record_counter(Micro::Core::PoolMetrics::CONNECTIONS_PRUNED, pruned.to_i64)
          update_enhanced_stats
        end
      end

      pruned
    end

    # Synchronize access to pool
    private def sync(&)
      @mutex.lock
      begin
        yield
      ensure
        @mutex.unlock
      end
    end

    # Temporarily release mutex for blocking operations
    private def unsync(&)
      @mutex.unlock
      begin
        yield
      ensure
        @mutex.lock
      end
    end

    # Waits for a connection to become available or until timeout.
    # Uses a channel to sleep until signaled by a returning connection.
    # Raises PoolTimeoutError if no connection becomes available within the timeout.
    private def wait_for_available
      select
      when @availability_channel.receive
        # Connection available
      when timeout(@config.acquire_timeout)
        raise PoolTimeoutError.new(
          Micro::Core::ErrorFormatter.timeout("acquire connection", @config.acquire_timeout)
        )
      end
    end

    # Selects and returns an available connection from the idle pool.
    # Validates the connection before returning it. If validation fails,
    # the connection is removed and nil is returned.
    private def pick_available : PooledConnection?
      conn = @idle.first?
      if conn && validate_connection(conn)
        conn
      elsif conn
        @idle.delete(conn)
        remove_connection(conn)
        update_enhanced_stats
        nil
      else
        nil
      end
    end

    # Checks if the pool can be expanded by creating a new connection.
    # Returns true if the total number of connections plus in-flight
    # connections is below max_size.
    private def can_increase_pool? : Bool
      @connections.size + @inflight < @config.max_size
    end

    # Checks if more idle connections can be added to the pool.
    # Returns true if idle count is below max_idle_pool_size.
    private def can_increase_idle? : Bool
      @idle.size < @config.max_idle
    end

    # Creates a new pooled connection to the server.
    # Records metrics for the creation attempt and timing.
    # Returns nil if connection creation fails.
    private def create_connection : PooledConnection?
      start_time = Time.utc

      begin
        socket = @factory.create
        conn = PooledConnection.new(socket)
        record_creation_metrics(start_time, true)
        conn
      rescue ex
        Log.error { "Failed to create connection: #{ex.message}" }
        record_creation_metrics(start_time, false)
        increment_errors
        nil
      end
    end

    # Validates that a connection is still healthy and usable.
    # Checks if the underlying socket is closed.
    # Returns true if the connection is valid, false otherwise.
    private def validate_connection(conn : PooledConnection) : Bool
      return true unless @config.health_check_enabled
      health_check(conn)
    end

    # Removes a connection from the pool and closes it.
    # Updates statistics and records the closure in metrics.
    # Ensures the connection is closed even if an error occurs.
    private def remove_connection(conn : PooledConnection)
      conn.socket.close rescue nil
      @connections.delete(conn)

      # Track closed connections
      @enhanced_stats.total_closed += 1
      record_counter(Micro::Core::PoolMetrics::CONNECTIONS_CLOSED)

      # Record connection lifetime metrics
      lifetime_ms = (Time.utc - conn.created_at).total_milliseconds
      record_metric(Micro::Core::PoolMetrics::CONNECTION_LIFETIME, lifetime_ms)
      record_metric(Micro::Core::PoolMetrics::CONNECTION_USE_COUNT, conn.use_count.to_f)

      # Stats will be updated by caller
    end

    # Updates the pool's connection statistics.
    # Counts total, active, and idle connections.
    private def update_stats
      @stats.total_connections = @connections.size
      @stats.active_connections = @connections.count(&.in_use?)
      @stats.idle_connections = @idle.size
    end

    # Records statistics for a connection acquisition attempt.
    # Calculates wait time and updates acquisition metrics.
    private def update_acquire_stats(start_time : Time)
      wait_ms = (Time.utc - start_time).total_milliseconds

      @stats.total_acquired += 1
      @enhanced_stats.total_acquired += 1

      # Update rolling average for both stats
      total = @stats.total_acquired
      @stats.avg_wait_time_ms = ((@stats.avg_wait_time_ms * (total - 1)) + wait_ms) / total
      @enhanced_stats.avg_wait_time_ms = calculate_average(
        @enhanced_stats.avg_wait_time_ms,
        wait_ms,
        @enhanced_stats.total_acquired
      )

      # Record metrics
      record_counter(Micro::Core::PoolMetrics::ACQUISITIONS_TOTAL)
      record_metric(Micro::Core::PoolMetrics::ACQUISITION_WAIT_TIME, wait_ms)

      update_enhanced_stats
    end

    # Increments timeout counters in pool statistics.
    # Updates both basic and enhanced statistics.
    private def increment_timeouts
      @stats.total_timeouts += 1
      @enhanced_stats.total_timeouts += 1
      record_counter(Micro::Core::PoolMetrics::ACQUISITIONS_TIMEOUTS)
    end

    # Increments error counters in pool statistics.
    # Updates both basic and enhanced statistics.
    private def increment_errors
      @stats.total_errors += 1
      @enhanced_stats.total_errors += 1
      record_counter(Micro::Core::PoolMetrics::ACQUISITIONS_ERRORS)
    end

    # MetricsCollectable interface implementation
    def metrics_collector : Micro::Core::MetricsCollector
      @metrics_collector
    end

    def enhanced_stats : Micro::Core::EnhancedPoolStats
      sync { @enhanced_stats.dup }
    end

    def pool_tags : Hash(String, String)
      tags = {
        "pool_type" => "http",
        "pool_id"   => object_id.to_s,
      }

      # Only add address if factory is HTTPConnectionFactory
      if factory = @factory.as?(HTTPConnectionFactory)
        tags["address"] = factory.address
      end

      tags.merge(@metrics_config.global_tags)
    end

    # Updates enhanced pool statistics including connection details.
    # Tracks healthy vs unhealthy connections and updates wait times.
    private def update_enhanced_stats
      # Update both old and new stats structures
      update_stats

      @enhanced_stats.total_connections = @connections.size
      @enhanced_stats.active_connections = @connections.count(&.in_use?)
      @enhanced_stats.idle_connections = @idle.size
      @enhanced_stats.creating_connections = @inflight
      @enhanced_stats.max_size = @config.max_size
      @enhanced_stats.max_idle = @config.max_idle
    end

    # Records metrics for connection creation attempts.
    # Tracks timing, success/failure rates, and updates counters.
    private def record_creation_metrics(start_time : Time, success : Bool)
      duration = Time.utc - start_time

      if success
        @enhanced_stats.total_created += 1
        @enhanced_stats.avg_creation_duration_ms = calculate_average(
          @enhanced_stats.avg_creation_duration_ms,
          duration.total_milliseconds,
          @enhanced_stats.total_created
        )

        record_counter(Micro::Core::PoolMetrics::CONNECTIONS_CREATED)
        record_metric(Micro::Core::PoolMetrics::CREATION_DURATION, duration.total_milliseconds)
      else
        record_counter(Micro::Core::PoolMetrics::CREATION_ERRORS)
      end
    end

    # Records metrics for health check operations.
    # Tracks timing and success/failure rates.
    private def record_health_check_metrics(start_time : Time, success : Bool)
      duration = Time.utc - start_time

      @enhanced_stats.health_checks_total += 1
      if !success
        @enhanced_stats.health_checks_failed += 1
      end

      @enhanced_stats.avg_health_check_duration_ms = calculate_average(
        @enhanced_stats.avg_health_check_duration_ms,
        duration.total_milliseconds,
        @enhanced_stats.health_checks_total
      )

      record_counter(Micro::Core::PoolMetrics::HEALTH_CHECKS_TOTAL)
      record_counter(Micro::Core::PoolMetrics::HEALTH_CHECKS_FAILED) unless success
      record_metric(Micro::Core::PoolMetrics::HEALTH_CHECK_DURATION, duration.total_milliseconds)
    end

    # Calculates a rolling average for metrics.
    # Uses incremental average formula to avoid overflow.
    private def calculate_average(current_avg : Float64, new_value : Float64, count : Int64) : Float64
      return new_value if count <= 1
      ((current_avg * (count - 1)) + new_value) / count
    end

    # Starts a background fiber that periodically reports pool metrics.
    # Reports every reporting_interval seconds if metrics are enabled.
    private def start_metrics_fiber
      @metrics_fiber = track_fiber("http-pool-metrics-#{object_id}") do
        loop do
          sleep @metrics_config.reporting_interval
          break if closed?

          begin
            report_metrics
          rescue ex
            Log.error { "Error during metrics reporting: #{ex.message}" }
          end
        end
      end
    end

    # Starts a background fiber that periodically prunes idle connections.
    # Removes connections that have been idle longer than max_idle_timeout.
    private def start_pruning_fiber
      @pruning_fiber = track_fiber("http-pool-pruning-#{object_id}") do
        loop do
          sleep @config.health_check_interval
          break if closed?

          begin
            pruned = prune
            Log.debug { "Pruned #{pruned} connections from pool" } if pruned > 0
          rescue ex
            Log.error { "Error during connection pruning: #{ex.message}" }
          end
        end
      end
    end
  end

  # Pool timeout error
  class PoolTimeoutError < Exception
  end

  # Factory for creating HTTP connections
  class HTTPConnectionFactory < Micro::Core::ConnectionFactory
    getter transport : Micro::Stdlib::Transports::HTTPTransport
    getter address : String
    getter dial_options : Micro::Core::DialOptions

    def initialize(@transport : Micro::Stdlib::Transports::HTTPTransport, @address : String, dial_options : Micro::Core::DialOptions? = nil)
      @dial_options = dial_options || Micro::Core::DialOptions.new
    end

    def create : Micro::Core::Socket
      @transport.dial(@address, @dial_options)
    end

    def validate(socket : Micro::Core::Socket) : Bool
      return false if socket.closed?

      # Use a simple ping check for validation
      begin
        # Send a minimal health check request
        message = Micro::Core::Message.new(
          body: Bytes.empty,
          type: Micro::Core::MessageType::Request,
          headers: {
            "X-HTTP-Method"     => "HEAD",
            "X-HTTP-Path"       => "/health",
            "X-Health-Check"    => "true",
            "X-Validation-Only" => "true",
          }
        )

        socket.send(message)

        # Wait for response with short timeout
        response = socket.receive(1.second)
        # Any response is good enough for basic validation
        response != nil
      rescue
        false
      end
    end
  end
end
