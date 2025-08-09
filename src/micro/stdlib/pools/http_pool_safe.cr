require "../../core/pool"
require "../../core/health_check_executor"
require "../../core/metrics"
require "../../core/closable_resource"
require "../../core/fiber_tracker"
require "../transports/http"
require "../health_checks/http_health_check"
require "../metrics/prometheus_metrics"
require "log"

module Micro::Stdlib::Pools
  # Thread-safe HTTP connection pool implementation
  # Fixes race conditions in the original HTTPConnectionPool
  class HTTPConnectionPoolSafe < Micro::Core::ConnectionPool
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
    @inflight : Atomic(Int32) # Make thread-safe
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
      @availability_channel = Channel(Nil).new(@config.max_size) # Bounded channel to prevent unbounded growth
      @inflight = Atomic(Int32).new(0)
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
      deadline = start_time + @config.acquire_timeout

      loop do
        # Try to get an idle connection
        conn = @mutex.synchronize do
          if available_conn = pick_available
            @idle.delete(available_conn)
            available_conn.acquire
            update_enhanced_stats
            available_conn
          else
            nil
          end
        end

        return conn if conn

        # No idle connections, try to create new one
        if can_increase_pool_safe?
          @inflight.add(1)
          begin
            if new_conn = create_connection
              added = @mutex.synchronize do
                if @connections.size < @config.max_size
                  @connections << new_conn
                  update_enhanced_stats
                  true
                else
                  # Pool filled while we were creating
                  false
                end
              end

              if added
                new_conn.acquire
                update_acquire_stats(start_time)
                return new_conn
              else
                # Close the connection we created but couldn't add
                new_conn.socket.close rescue nil
              end
            end
          ensure
            @inflight.sub(1)
          end
        end

        # Wait for a connection to become available
        remaining = deadline - Time.utc
        break if remaining <= Time::Span.zero

        select
        when @availability_channel.receive?
          # A connection might be available, loop to try again
        when timeout(remaining)
          # Timeout reached
          break
        end
      end

      # Timeout reached
      increment_timeouts
      nil
    end

    def release(connection : PooledConnection) : Nil
      return if closed?

      should_notify = false

      @mutex.synchronize do
        connection.release

        if validate_connection(connection) && can_increase_idle?
          @idle << connection
          should_notify = true
        else
          remove_connection(connection)
        end

        update_enhanced_stats
      end

      # Notify waiting fibers outside of mutex
      if should_notify
        select
        when @availability_channel.send(nil)
        else
          # Channel full, no problem
        end
      end
    end

    # Implement the perform_close method required by ClosableResource
    protected def perform_close : Nil
      Log.debug { "Closing HTTP connection pool" }

      # First, prevent new acquisitions
      @availability_channel.close rescue nil

      # Shutdown background fibers
      shutdown_fibers(5.seconds)

      # Close all connections
      @mutex.synchronize do
        @connections.each do |conn|
          conn.socket.close rescue nil
        end
        @connections.clear
        @idle.clear
      end

      Log.debug { "HTTP connection pool closed" }
    end

    def stats : Stats
      @mutex.synchronize { @stats.dup }
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
        @mutex.synchronize do
          @stats.total_errors += 1
        end
      end

      result.healthy?
    end

    def prune : Int32
      pruned = 0
      to_remove = [] of PooledConnection

      @mutex.synchronize do
        @connections.each do |conn|
          next if conn.in_use?

          if !health_check(conn)
            @idle.delete(conn)
            to_remove << conn
            pruned += 1
          end
        end

        # Remove unhealthy connections
        to_remove.each { |conn| remove_connection(conn) }
        update_enhanced_stats
      end

      Log.debug { "Pruned #{pruned} unhealthy connections" } if pruned > 0
      pruned
    end

    # Thread-safe version that checks atomically
    private def can_increase_pool_safe? : Bool
      current_size = @mutex.synchronize { @connections.size }
      current_inflight = @inflight.get
      current_size + current_inflight < @config.max_size
    end

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

    private def can_increase_idle? : Bool
      @idle.size < @config.max_idle
    end

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

    private def validate_connection(conn : PooledConnection) : Bool
      return true unless @config.health_check_enabled
      health_check(conn)
    end

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
    end

    private def update_stats
      @stats.total_connections = @connections.size
      @stats.active_connections = @connections.count(&.in_use?)
      @stats.idle_connections = @idle.size
    end

    private def update_acquire_stats(start_time : Time)
      wait_ms = (Time.utc - start_time).total_milliseconds

      @mutex.synchronize do
        @stats.total_acquired += 1
        @enhanced_stats.total_acquired += 1

        # Update rolling average
        total = @stats.total_acquired
        @stats.avg_wait_time_ms = ((@stats.avg_wait_time_ms * (total - 1)) + wait_ms) / total
        @enhanced_stats.avg_wait_time_ms = calculate_average(
          @enhanced_stats.avg_wait_time_ms,
          wait_ms,
          @enhanced_stats.total_acquired
        )
      end

      # Record metrics
      record_counter(Micro::Core::PoolMetrics::ACQUISITIONS_TOTAL)
      record_metric(Micro::Core::PoolMetrics::ACQUISITION_WAIT_TIME, wait_ms)
    end

    private def increment_timeouts
      @mutex.synchronize do
        @stats.total_timeouts += 1
        @enhanced_stats.total_timeouts += 1
      end
      record_counter(Micro::Core::PoolMetrics::ACQUISITIONS_TIMEOUTS)
    end

    private def increment_errors
      @mutex.synchronize do
        @stats.total_errors += 1
        @enhanced_stats.total_errors += 1
      end
      record_counter(Micro::Core::PoolMetrics::ACQUISITIONS_ERRORS)
    end

    # MetricsCollectable interface implementation
    def metrics_collector : Micro::Core::MetricsCollector
      @metrics_collector
    end

    def enhanced_stats : Micro::Core::EnhancedPoolStats
      @mutex.synchronize { @enhanced_stats.dup }
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

    private def update_enhanced_stats
      # Update both old and new stats structures
      update_stats

      @enhanced_stats.total_connections = @connections.size
      @enhanced_stats.active_connections = @connections.count(&.in_use?)
      @enhanced_stats.idle_connections = @idle.size
      @enhanced_stats.creating_connections = @inflight.get
      @enhanced_stats.max_size = @config.max_size
      @enhanced_stats.max_idle = @config.max_idle
    end

    private def record_creation_metrics(start_time : Time, success : Bool)
      duration = Time.utc - start_time
      duration_ms = duration.total_milliseconds

      record_metric(Micro::Core::PoolMetrics::CONNECTION_CREATION_TIME, duration_ms)
      if success
        record_counter(Micro::Core::PoolMetrics::CONNECTIONS_CREATED)
      else
        record_counter(Micro::Core::PoolMetrics::CONNECTION_CREATION_FAILURES)
      end
    end

    private def record_health_check_metrics(start_time : Time, success : Bool)
      duration = Time.utc - start_time
      duration_ms = duration.total_milliseconds

      record_metric(Micro::Core::PoolMetrics::HEALTH_CHECK_DURATION, duration_ms)
      if success
        record_counter(Micro::Core::PoolMetrics::HEALTH_CHECKS_PASSED)
      else
        record_counter(Micro::Core::PoolMetrics::HEALTH_CHECKS_FAILED)
      end
    end

    private def calculate_average(current : Float64, new_value : Float64, count : Int64) : Float64
      return new_value if count == 1
      ((current * (count - 1)) + new_value) / count
    end

    private def start_pruning_fiber
      @pruning_fiber = track_fiber("pool-prune-#{object_id}") do
        loop do
          sleep @config.health_check_interval
          break if closed?

          begin
            prune
          rescue ex
            Log.error(exception: ex) { "Error during connection pruning" }
          end
        end
      end
    end

    private def start_metrics_fiber
      @metrics_fiber = track_fiber("pool-metrics-#{object_id}") do
        loop do
          sleep @metrics_config.reporting_interval
          break if closed?

          begin
            @mutex.synchronize do
              record_gauge(Micro::Core::PoolMetrics::CONNECTIONS_TOTAL, @connections.size.to_f)
              record_gauge(Micro::Core::PoolMetrics::CONNECTIONS_ACTIVE, @connections.count(&.in_use?).to_f)
              record_gauge(Micro::Core::PoolMetrics::CONNECTIONS_IDLE, @idle.size.to_f)
              record_gauge(Micro::Core::PoolMetrics::CONNECTIONS_CREATING, @inflight.get.to_f)
            end
          rescue ex
            Log.error(exception: ex) { "Error recording pool metrics" }
          end
        end
      end
    end

    # HealthCheckable interface
    private def health_check_with_retry(connection : PooledConnection) : Micro::Core::HealthCheckResult
      @health_check_executor.check_health(connection.socket)
    end

    # Custom pool timeout error
    class PoolTimeoutError < Exception
      def initialize(message : String)
        super(message)
      end
    end
  end
end
