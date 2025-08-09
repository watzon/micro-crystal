require "../../spec_helper"
require "../../../src/micro/core/metrics"

describe Micro::Core::NoOpMetricsCollector do
  it "does nothing for all methods" do
    collector = Micro::Core::NoOpMetricsCollector.new
    # These should not raise or cause any side effects
    collector.counter("test")
    collector.counter("test", 5_i64)
    collector.gauge("test", 42.0)
    collector.histogram("test", 123.0)
    collector.timing("test", 100.milliseconds)

    result = collector.time("test") { "result" }
    result.should eq("result")
  end
end

describe Micro::Core::EnhancedPoolStats do
  describe "#utilization_percent" do
    it "calculates pool utilization correctly" do
      stats = Micro::Core::EnhancedPoolStats.new(max_size: 10, max_idle: 5)
      stats.total_connections = 7
      stats.utilization_percent.should eq(70.0)
    end

    it "handles zero max_size" do
      stats_zero = Micro::Core::EnhancedPoolStats.new(max_size: 0)
      stats_zero.utilization_percent.should eq(0.0)
    end
  end

  describe "#pressure_percent" do
    it "calculates pool pressure correctly" do
      stats = Micro::Core::EnhancedPoolStats.new(max_size: 10, max_idle: 5)
      stats.total_acquired = 100_i64
      stats.total_timeouts = 15_i64
      stats.pressure_percent.should eq(15.0)
    end

    it "handles zero acquisitions" do
      stats = Micro::Core::EnhancedPoolStats.new(max_size: 10, max_idle: 5)
      stats.total_acquired = 0_i64
      stats.pressure_percent.should eq(0.0)
    end
  end

  describe "#health_check_success_rate" do
    it "calculates success rate correctly" do
      stats = Micro::Core::EnhancedPoolStats.new(max_size: 10, max_idle: 5)
      stats.health_checks_total = 50_i64
      stats.health_checks_failed = 5_i64
      stats.health_check_success_rate.should eq(90.0)
    end

    it "handles zero health checks" do
      stats = Micro::Core::EnhancedPoolStats.new(max_size: 10, max_idle: 5)
      stats.health_checks_total = 0_i64
      stats.health_check_success_rate.should eq(100.0)
    end
  end

  describe "#report_to" do
    it "reports all metrics to collector" do
      stats = Micro::Core::EnhancedPoolStats.new(max_size: 10, max_idle: 5)
      collector = TestMetricsCollector.new
      tags = {"pool" => "test"}

      stats.total_connections = 5
      stats.active_connections = 3
      stats.idle_connections = 2
      stats.total_acquired = 100_i64
      stats.avg_wait_time_ms = 25.5

      stats.report_to(collector, tags)

      collector.gauges[{Micro::Core::PoolMetrics::CONNECTIONS_TOTAL, tags}].should eq(5.0)
      collector.gauges[{Micro::Core::PoolMetrics::CONNECTIONS_ACTIVE, tags}].should eq(3.0)
      collector.gauges[{Micro::Core::PoolMetrics::CONNECTIONS_IDLE, tags}].should eq(2.0)
      collector.counters[{Micro::Core::PoolMetrics::ACQUISITIONS_TOTAL, tags}].should eq(100_i64)
      collector.gauges[{Micro::Core::PoolMetrics::ACQUISITION_WAIT_TIME, tags}].should eq(25.5)
    end
  end
end

# Test helper class for capturing metrics calls
class TestMetricsCollector < Micro::Core::MetricsCollector
  getter counters = Hash({String, Hash(String, String)}, Int64).new
  getter gauges = Hash({String, Hash(String, String)}, Float64).new
  getter histograms = Hash({String, Hash(String, String)}, Float64).new

  def counter(name : String, tags : Hash(String, String) = {} of String => String) : Nil
    counter(name, 1_i64, tags)
  end

  def counter(name : String, value : Int64, tags : Hash(String, String) = {} of String => String) : Nil
    key = {name, tags}
    @counters[key] = (@counters[key]? || 0_i64) + value
  end

  def gauge(name : String, value : Float64, tags : Hash(String, String) = {} of String => String) : Nil
    @gauges[{name, tags}] = value
  end

  def histogram(name : String, value : Float64, tags : Hash(String, String) = {} of String => String) : Nil
    @histograms[{name, tags}] = value
  end

  def clear
    @counters.clear
    @gauges.clear
    @histograms.clear
  end
end
