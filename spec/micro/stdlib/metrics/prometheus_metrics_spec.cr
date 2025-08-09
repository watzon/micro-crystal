require "../../../spec_helper"
require "../../../../src/micro/stdlib/metrics/prometheus_metrics"

describe Micro::Stdlib::Metrics::PrometheusMetricsCollector do
  describe "#counter" do
    it "increments counters by 1 by default" do
      collector = Micro::Stdlib::Metrics::PrometheusMetricsCollector.new
      collector.counter("test_counter")
      collector.counter("test_counter")

      snapshot = collector.snapshot
      snapshot["test_counter"]["test_counter"].should eq(2.0)
    end

    it "increments counters by specified value" do
      collector = Micro::Stdlib::Metrics::PrometheusMetricsCollector.new
      collector.counter("test_counter", 5_i64)
      collector.counter("test_counter", 3_i64)

      snapshot = collector.snapshot
      snapshot["test_counter"]["test_counter"].should eq(8.0)
    end

    it "handles counters with tags" do
      collector = Micro::Stdlib::Metrics::PrometheusMetricsCollector.new
      collector.counter("test_counter", {"service" => "test", "env" => "dev"})
      collector.counter("test_counter", {"service" => "test", "env" => "prod"})

      snapshot = collector.snapshot
      snapshot["test_counter"].size.should eq(2)
    end
  end

  describe "#gauge" do
    it "sets gauge values" do
      collector = Micro::Stdlib::Metrics::PrometheusMetricsCollector.new
      collector.gauge("test_gauge", 42.5)
      collector.gauge("test_gauge", 37.2) # Should replace previous value

      snapshot = collector.snapshot
      snapshot["test_gauge"]["test_gauge"].should eq(37.2)
    end

    it "handles gauges with tags" do
      collector = Micro::Stdlib::Metrics::PrometheusMetricsCollector.new
      collector.gauge("test_gauge", 100.0, {"type" => "memory"})
      collector.gauge("test_gauge", 75.0, {"type" => "cpu"})

      snapshot = collector.snapshot
      snapshot["test_gauge"].size.should eq(2)
    end
  end

  describe "#histogram" do
    it "creates histogram metrics" do
      collector = Micro::Stdlib::Metrics::PrometheusMetricsCollector.new
      collector.histogram("test_histogram", 123.45)

      snapshot = collector.snapshot
      snapshot["test_histogram_current"]["test_histogram_current"].should eq(123.45)
      snapshot["test_histogram_count"]["test_histogram_count"].should eq(1.0)
      snapshot["test_histogram_sum"]["test_histogram_sum"].should eq(123.45)
    end
  end

  describe "#timing" do
    it "records timing metrics" do
      collector = Micro::Stdlib::Metrics::PrometheusMetricsCollector.new
      duration = 150.milliseconds
      collector.timing("test_timing", duration)

      snapshot = collector.snapshot
      snapshot["test_timing_current"]["test_timing_current"].should eq(150.0)
    end
  end

  describe "#time" do
    it "measures and records execution time" do
      collector = Micro::Stdlib::Metrics::PrometheusMetricsCollector.new
      result = collector.time("test_operation") do
        sleep 10.milliseconds
        "result"
      end

      result.should eq("result")
      snapshot = collector.snapshot
      snapshot["test_operation_current"]["test_operation_current"].should be > 0.0
    end
  end

  describe "#export_prometheus" do
    it "exports metrics in Prometheus format" do
      collector = Micro::Stdlib::Metrics::PrometheusMetricsCollector.new
      collector.counter("http_requests_total", {"method" => "GET", "status" => "200"})
      collector.gauge("pool_connections_active", 5.0, {"pool" => "http"})

      output = collector.export_prometheus

      output.should contain("# HELP http_requests_total")
      output.should contain("# TYPE http_requests_total counter")
      output.should contain("http_requests_total{method=\"GET\",status=\"200\"}")

      output.should contain("# HELP pool_connections_active")
      output.should contain("# TYPE pool_connections_active gauge")
      output.should contain("pool_connections_active{pool=\"http\"} 5.0")
    end

    it "handles empty metrics" do
      collector = Micro::Stdlib::Metrics::PrometheusMetricsCollector.new
      output = collector.export_prometheus
      output.should eq("")
    end
  end

  describe "#clear" do
    it "removes all metrics" do
      collector = Micro::Stdlib::Metrics::PrometheusMetricsCollector.new
      collector.counter("test_counter")
      collector.gauge("test_gauge", 42.0)
      collector.metric_count.should be > 0

      collector.clear
      collector.metric_count.should eq(0)
    end
  end
end

describe Micro::Stdlib::Metrics::MetricsFactory do
  describe ".prometheus" do
    it "creates a PrometheusMetricsCollector" do
      collector = Micro::Stdlib::Metrics::MetricsFactory.prometheus
      collector.should be_a(Micro::Stdlib::Metrics::PrometheusMetricsCollector)
    end
  end

  describe ".noop" do
    it "creates a NoOpMetricsCollector" do
      collector = Micro::Stdlib::Metrics::MetricsFactory.noop
      collector.should be_a(Micro::Core::NoOpMetricsCollector)
    end
  end

  describe ".default_collector" do
    it "returns NoOpMetricsCollector by default" do
      collector = Micro::Stdlib::Metrics::MetricsFactory.default_collector
      collector.should be_a(Micro::Core::NoOpMetricsCollector)
    end

    it "can be set to a custom collector" do
      custom_collector = Micro::Stdlib::Metrics::MetricsFactory.prometheus
      Micro::Stdlib::Metrics::MetricsFactory.default_collector = custom_collector

      retrieved_collector = Micro::Stdlib::Metrics::MetricsFactory.default_collector
      retrieved_collector.should be(custom_collector)

      # Reset to default
      Micro::Stdlib::Metrics::MetricsFactory.default_collector = Micro::Core::NoOpMetricsCollector.new
    end
  end
end
