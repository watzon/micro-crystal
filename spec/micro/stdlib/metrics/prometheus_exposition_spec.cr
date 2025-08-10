require "../../../spec_helper"
require "../../../../src/micro/stdlib/metrics/prometheus_metrics"

describe Micro::Stdlib::Metrics::PrometheusMetricsCollector do
  it "exports counters and gauges in prometheus format" do
    c = Micro::Stdlib::Metrics::PrometheusMetricsCollector.new
    c.counter("requests_total")
    c.gauge("queue_depth", 5.0)

    text = c.export_prometheus
    text.should contain("# TYPE requests_total counter")
    text.should contain("requests_total 1")
    text.should contain("# TYPE queue_depth gauge")
    text.should contain("queue_depth 5")
  end
end
