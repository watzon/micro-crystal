require "../../core/metrics"
require "log"
require "mutex"

module Micro::Stdlib::Metrics
  Log = ::Log.for("micro.metrics")

  # Prometheus-style metrics collector
  # Stores metrics in memory for scraping via HTTP endpoint
  class PrometheusMetricsCollector < Micro::Core::MetricsCollector
    # Metric types
    enum MetricType
      Counter
      Gauge
      Histogram
    end

    # Individual metric sample
    struct MetricSample
      property name : String
      property value : Float64
      property tags : Hash(String, String)
      property timestamp : Time
      property type : MetricType

      def initialize(@name : String, @value : Float64, @tags : Hash(String, String), @type : MetricType)
        @timestamp = Time.utc
      end

      # Format as Prometheus exposition format
      def to_prometheus : String
        String.build do |str|
          str << name

          # Add labels if present
          unless tags.empty?
            str << "{"
            tag_pairs = tags.map { |k, v| "#{k}=\"#{escape_label_value(v)}\"" }
            str << tag_pairs.join(",")
            str << "}"
          end

          str << " "
          str << value
          str << " "
          str << timestamp.to_unix_ms
        end
      end

      private def escape_label_value(value : String) : String
        value.gsub("\\", "\\\\").gsub("\"", "\\\"").gsub("\n", "\\n")
      end
    end

    # Thread-safe storage for metrics
    @metrics : Hash(String, Hash(String, MetricSample))
    @mutex : Mutex

    def initialize
      @metrics = Hash(String, Hash(String, MetricSample)).new
      @mutex = Mutex.new
    end

    def counter(name : String, tags : Hash(String, String) = {} of String => String) : Nil
      counter(name, 1_i64, tags)
    end

    def counter(name : String, value : Int64, tags : Hash(String, String) = {} of String => String) : Nil
      key = build_metric_key(name, tags)

      @mutex.synchronize do
        metric_family = @metrics[name] ||= Hash(String, MetricSample).new

        if existing = metric_family[key]?
          # Increment existing counter
          metric_family[key] = MetricSample.new(name, existing.value + value.to_f, tags, MetricType::Counter)
        else
          # Create new counter
          metric_family[key] = MetricSample.new(name, value.to_f, tags, MetricType::Counter)
        end
      end
    end

    def gauge(name : String, value : Float64, tags : Hash(String, String) = {} of String => String) : Nil
      key = build_metric_key(name, tags)

      @mutex.synchronize do
        metric_family = @metrics[name] ||= Hash(String, MetricSample).new
        metric_family[key] = MetricSample.new(name, value, tags, MetricType::Gauge)
      end
    end

    def histogram(name : String, value : Float64, tags : Hash(String, String) = {} of String => String) : Nil
      # For simplicity, we'll treat histograms as gauges for now
      # A full implementation would maintain buckets and quantiles
      gauge("#{name}_current", value, tags)
      counter("#{name}_count", tags)
      gauge("#{name}_sum", value, tags)
    end

    # Export all metrics in Prometheus exposition format
    def export_prometheus : String
      String.build do |output|
        @mutex.synchronize do
          @metrics.each do |metric_name, samples|
            # Add TYPE and HELP comments for each metric family
            sample = samples.values.first?
            next unless sample

            output << "# HELP #{metric_name} #{generate_help_text(metric_name)}\n"
            output << "# TYPE #{metric_name} #{sample.type.to_s.downcase}\n"

            # Output all samples for this metric family
            samples.each_value do |sample|
              output << sample.to_prometheus << "\n"
            end
            output << "\n"
          end
        end
      end
    end

    # Get all current metrics as a hash
    def snapshot : Hash(String, Hash(String, Float64))
      result = Hash(String, Hash(String, Float64)).new

      @mutex.synchronize do
        @metrics.each do |metric_name, samples|
          result[metric_name] = Hash(String, Float64).new
          samples.each do |key, sample|
            result[metric_name][key] = sample.value
          end
        end
      end

      result
    end

    # Clear all metrics (useful for testing)
    def clear : Nil
      @mutex.synchronize do
        @metrics.clear
      end
    end

    # Get metric count (for testing/debugging)
    def metric_count : Int32
      @mutex.synchronize do
        @metrics.values.sum(&.size)
      end
    end

    private def build_metric_key(name : String, tags : Hash(String, String)) : String
      return name if tags.empty?

      # Sort tags for consistent keys
      sorted_tags = tags.to_a.sort_by(&.first)
      tag_string = sorted_tags.map { |k, v| "#{k}=#{v}" }.join(",")
      "#{name}[#{tag_string}]"
    end

    private def generate_help_text(metric_name : String) : String
      case metric_name
      when .includes?("pool.connections.total")
        "Total number of connections in the pool"
      when .includes?("pool.connections.active")
        "Number of connections currently in use"
      when .includes?("pool.connections.idle")
        "Number of idle connections available"
      when .includes?("pool.acquisitions.total")
        "Total number of connection acquisitions attempted"
      when .includes?("pool.acquisitions.timeouts")
        "Number of connection acquisition timeouts"
      when .includes?("pool.acquisitions.errors")
        "Number of connection acquisition errors"
      when .includes?("pool.health_checks.total")
        "Total number of health checks performed"
      when .includes?("pool.health_checks.failed")
        "Number of failed health checks"
      when .includes?("pool.utilization.percent")
        "Pool utilization as percentage of max size"
      when .includes?("pool.pressure.percent")
        "Pool pressure as percentage of timeouts vs acquisitions"
      else
        "Micro-Crystal pool metric"
      end
    end
  end

  # Configuration for metrics collection
  struct MetricsConfig
    # Whether metrics collection is enabled
    property enabled : Bool

    # Interval for periodic metrics reporting
    property reporting_interval : Time::Span

    # Additional global tags to add to all metrics
    property global_tags : Hash(String, String)

    # Whether to enable detailed timing metrics (may impact performance)
    property detailed_timings : Bool

    def initialize(
      @enabled : Bool = true,
      @reporting_interval : Time::Span = 30.seconds,
      @global_tags : Hash(String, String) = {} of String => String,
      @detailed_timings : Bool = false,
    )
    end
  end

  # Factory for creating metrics collectors
  class MetricsFactory
    @@default_collector : Micro::Core::MetricsCollector?

    # Set the default metrics collector
    def self.default_collector=(collector : Micro::Core::MetricsCollector)
      @@default_collector = collector
    end

    # Get the default metrics collector
    def self.default_collector : Micro::Core::MetricsCollector
      @@default_collector ||= Micro::Core::NoOpMetricsCollector.new
    end

    # Create a new Prometheus collector
    def self.prometheus : PrometheusMetricsCollector
      PrometheusMetricsCollector.new
    end

    # Create a no-op collector
    def self.noop : Micro::Core::NoOpMetricsCollector
      Micro::Core::NoOpMetricsCollector.new
    end
  end
end
