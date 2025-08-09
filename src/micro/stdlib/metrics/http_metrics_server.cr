require "http/server"
require "log"
require "./prometheus_metrics"

module Micro::Stdlib::Metrics
  Log = ::Log.for("micro.metrics.http")

  # Simple HTTP server for exposing Prometheus metrics
  class HTTPMetricsServer
    getter host : String
    getter port : Int32
    getter collector : PrometheusMetricsCollector

    @server : HTTP::Server?
    @running : Bool = false

    def initialize(@host : String = "0.0.0.0", @port : Int32 = 9090, @collector : PrometheusMetricsCollector = PrometheusMetricsCollector.new)
    end

    # Start the metrics server
    def start : Nil
      return if @running

      @server = HTTP::Server.new do |context|
        handle_request(context)
      end

      if server = @server
        server.bind_tcp(@host, @port)

        @running = true
        Log.info { "Metrics server starting on http://#{@host}:#{@port}" }

        spawn do
          begin
            server.listen
          rescue ex
            Log.error { "Metrics server error: #{ex.message}" }
            @running = false
          end
        end
      end
    end

    # Stop the metrics server
    def stop : Nil
      return unless @running

      if server = @server
        server.close
        @server = nil
        @running = false
        Log.info { "Metrics server stopped" }
      end
    end

    # Check if server is running
    def running? : Bool
      @running
    end

    private def handle_request(context : HTTP::Server::Context)
      request = context.request
      response = context.response

      case request.path
      when "/metrics"
        handle_metrics(response)
      when "/health"
        handle_health(response)
      else
        handle_not_found(response)
      end
    end

    private def handle_metrics(response : HTTP::Server::Response)
      metrics_data = @collector.export_prometheus
      response.status_code = 200
      response.headers["Content-Type"] = "text/plain; version=0.0.4; charset=utf-8"
      response.print(metrics_data)
    rescue ex
      Log.error { "Error generating metrics: #{ex.message}" }
      response.status_code = 500
      response.print("Internal Server Error\n")
    end

    private def handle_health(response : HTTP::Server::Response)
      response.status_code = 200
      response.headers["Content-Type"] = "application/json"
      response.print("{\"status\":\"ok\",\"uptime\":\"#{Process.uptime}\"}\n")
    end

    private def handle_not_found(response : HTTP::Server::Response)
      response.status_code = 404
      response.headers["Content-Type"] = "text/plain"
      response.print("Not Found\n")
    end
  end

  # Configuration for HTTP metrics server
  struct HTTPMetricsConfig
    property enabled : Bool
    property host : String
    property port : Int32
    property path : String

    def initialize(
      @enabled : Bool = false,
      @host : String = "0.0.0.0",
      @port : Int32 = 9090,
      @path : String = "/metrics",
    )
    end
  end

  # Global metrics server instance
  class MetricsRegistry
    @@instance : MetricsRegistry?
    @@collector : PrometheusMetricsCollector?
    @@server : HTTPMetricsServer?

    # Get the singleton instance
    def self.instance : MetricsRegistry
      @@instance ||= new
    end

    # Get or create the global metrics collector
    def self.collector : PrometheusMetricsCollector
      @@collector ||= PrometheusMetricsCollector.new
    end

    # Start the HTTP metrics server
    def self.start_server(config : HTTPMetricsConfig = HTTPMetricsConfig.new) : HTTPMetricsServer?
      return nil unless config.enabled

      @@server ||= HTTPMetricsServer.new(config.host, config.port, collector)

      if server = @@server
        server.start unless server.running?
        server
      end
    end

    # Stop the HTTP metrics server
    def self.stop_server : Nil
      if server = @@server
        server.stop
        @@server = nil
      end
    end

    # Get the current server instance
    def self.server : HTTPMetricsServer?
      @@server
    end

    # Set the default metrics collector
    def self.set_default_collector(collector : Micro::Core::MetricsCollector) : Nil
      MetricsFactory.default_collector = collector
    end
  end
end
