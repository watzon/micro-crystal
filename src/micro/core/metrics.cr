require "time"

module Micro::Core
  # Metrics collection interface for monitoring pool performance
  # Provides extensible metrics collection with pluggable backends
  abstract class MetricsCollector
    # Record a counter metric (increments by 1)
    abstract def counter(name : String, tags : Hash(String, String) = {} of String => String) : Nil

    # Record a counter metric with a specific value
    abstract def counter(name : String, value : Int64, tags : Hash(String, String) = {} of String => String) : Nil

    # Record a gauge metric (current value at a point in time)
    abstract def gauge(name : String, value : Float64, tags : Hash(String, String) = {} of String => String) : Nil

    # Record a histogram metric (distribution of values)
    abstract def histogram(name : String, value : Float64, tags : Hash(String, String) = {} of String => String) : Nil

    # Record timing information
    def timing(name : String, duration : Time::Span, tags : Hash(String, String) = {} of String => String) : Nil
      histogram(name, duration.total_milliseconds, tags)
    end

    # Measure and record the execution time of a block
    def time(name : String, tags : Hash(String, String) = {} of String => String, &)
      start_time = Time.utc
      result = yield
      duration = Time.utc - start_time
      timing(name, duration, tags)
      result
    end
  end

  # No-op metrics collector for when metrics are disabled
  class NoOpMetricsCollector < MetricsCollector
    def counter(name : String, tags : Hash(String, String) = {} of String => String) : Nil
    end

    def counter(name : String, value : Int64, tags : Hash(String, String) = {} of String => String) : Nil
    end

    def gauge(name : String, value : Float64, tags : Hash(String, String) = {} of String => String) : Nil
    end

    def histogram(name : String, value : Float64, tags : Hash(String, String) = {} of String => String) : Nil
    end
  end

  # Pool-specific metrics collection
  module PoolMetrics
    # Pool metrics names - standardized across all pool implementations
    CONNECTIONS_TOTAL    = "pool.connections.total"
    CONNECTIONS_ACTIVE   = "pool.connections.active"
    CONNECTIONS_IDLE     = "pool.connections.idle"
    CONNECTIONS_CREATING = "pool.connections.creating"

    # Acquisition metrics
    ACQUISITIONS_TOTAL    = "pool.acquisitions.total"
    ACQUISITIONS_TIMEOUTS = "pool.acquisitions.timeouts"
    ACQUISITIONS_ERRORS   = "pool.acquisitions.errors"
    ACQUISITION_WAIT_TIME = "pool.acquisition.wait_time_ms"

    # Health check metrics
    HEALTH_CHECKS_TOTAL   = "pool.health_checks.total"
    HEALTH_CHECKS_FAILED  = "pool.health_checks.failed"
    HEALTH_CHECK_DURATION = "pool.health_check.duration_ms"

    # Connection lifecycle metrics
    CONNECTIONS_CREATED  = "pool.connections.created"
    CONNECTIONS_CLOSED   = "pool.connections.closed"
    CONNECTIONS_PRUNED   = "pool.connections.pruned"
    CONNECTION_LIFETIME  = "pool.connection.lifetime_ms"
    CONNECTION_USE_COUNT = "pool.connection.use_count"

    # Pool utilization metrics
    POOL_UTILIZATION = "pool.utilization.percent"
    POOL_PRESSURE    = "pool.pressure.percent"

    # Factory/creation metrics
    CREATION_ERRORS   = "pool.creation.errors"
    CREATION_DURATION = "pool.creation.duration_ms"
  end

  # Enhanced stats with metrics collection
  struct EnhancedPoolStats
    include PoolMetrics

    # Current state
    property total_connections : Int32
    property active_connections : Int32
    property idle_connections : Int32
    property creating_connections : Int32

    # Cumulative counters
    property total_acquired : Int64
    property total_timeouts : Int64
    property total_errors : Int64
    property total_created : Int64
    property total_closed : Int64
    property total_pruned : Int64

    # Health check metrics
    property health_checks_total : Int64
    property health_checks_failed : Int64

    # Timing metrics
    property avg_wait_time_ms : Float64
    property avg_health_check_duration_ms : Float64
    property avg_creation_duration_ms : Float64

    # Pool configuration for calculating utilization
    property max_size : Int32
    property max_idle : Int32

    def initialize(
      @total_connections : Int32 = 0,
      @active_connections : Int32 = 0,
      @idle_connections : Int32 = 0,
      @creating_connections : Int32 = 0,
      @total_acquired : Int64 = 0,
      @total_timeouts : Int64 = 0,
      @total_errors : Int64 = 0,
      @total_created : Int64 = 0,
      @total_closed : Int64 = 0,
      @total_pruned : Int64 = 0,
      @health_checks_total : Int64 = 0,
      @health_checks_failed : Int64 = 0,
      @avg_wait_time_ms : Float64 = 0.0,
      @avg_health_check_duration_ms : Float64 = 0.0,
      @avg_creation_duration_ms : Float64 = 0.0,
      @max_size : Int32 = 10,
      @max_idle : Int32 = 5,
    )
    end

    # Calculate pool utilization as percentage
    def utilization_percent : Float64
      return 0.0 if max_size == 0
      (total_connections.to_f / max_size.to_f) * 100.0
    end

    # Calculate pool pressure (how often we're hitting limits)
    def pressure_percent : Float64
      return 0.0 if total_acquired == 0
      (total_timeouts.to_f / total_acquired.to_f) * 100.0
    end

    # Health check success rate
    def health_check_success_rate : Float64
      return 100.0 if health_checks_total == 0
      success = health_checks_total - health_checks_failed
      (success.to_f / health_checks_total.to_f) * 100.0
    end

    # Report all metrics to collector
    def report_to(collector : MetricsCollector, tags : Hash(String, String) = {} of String => String) : Nil
      # Current state gauges
      collector.gauge(CONNECTIONS_TOTAL, total_connections.to_f, tags)
      collector.gauge(CONNECTIONS_ACTIVE, active_connections.to_f, tags)
      collector.gauge(CONNECTIONS_IDLE, idle_connections.to_f, tags)
      collector.gauge(CONNECTIONS_CREATING, creating_connections.to_f, tags)

      # Cumulative counters
      collector.counter(ACQUISITIONS_TOTAL, total_acquired, tags)
      collector.counter(ACQUISITIONS_TIMEOUTS, total_timeouts, tags)
      collector.counter(ACQUISITIONS_ERRORS, total_errors, tags)
      collector.counter(CONNECTIONS_CREATED, total_created, tags)
      collector.counter(CONNECTIONS_CLOSED, total_closed, tags)
      collector.counter(CONNECTIONS_PRUNED, total_pruned, tags)

      # Health check metrics
      collector.counter(HEALTH_CHECKS_TOTAL, health_checks_total, tags)
      collector.counter(HEALTH_CHECKS_FAILED, health_checks_failed, tags)

      # Timing metrics
      collector.gauge(ACQUISITION_WAIT_TIME, avg_wait_time_ms, tags)
      collector.gauge(HEALTH_CHECK_DURATION, avg_health_check_duration_ms, tags)
      collector.gauge(CREATION_DURATION, avg_creation_duration_ms, tags)

      # Utilization metrics
      collector.gauge(POOL_UTILIZATION, utilization_percent, tags)
      collector.gauge(POOL_PRESSURE, pressure_percent, tags)
    end
  end

  # Mixin for connection pools to add metrics collection
  module MetricsCollectable
    abstract def metrics_collector : MetricsCollector
    abstract def enhanced_stats : EnhancedPoolStats
    abstract def pool_tags : Hash(String, String)

    # Record a metric with pool-specific tags
    def record_metric(name : String, value : Float64, additional_tags : Hash(String, String) = {} of String => String) : Nil
      all_tags = pool_tags.merge(additional_tags)
      metrics_collector.gauge(name, value, all_tags)
    end

    # Record a counter metric
    def record_counter(name : String, value : Int64 = 1_i64, additional_tags : Hash(String, String) = {} of String => String) : Nil
      all_tags = pool_tags.merge(additional_tags)
      metrics_collector.counter(name, value, all_tags)
    end

    # Time an operation and record the duration
    def time_operation(name : String, additional_tags : Hash(String, String) = {} of String => String, &)
      all_tags = pool_tags.merge(additional_tags)
      metrics_collector.time(name, all_tags) { yield }
    end

    # Periodic metrics reporting
    def report_metrics : Nil
      enhanced_stats.report_to(metrics_collector, pool_tags)
    end
  end
end
