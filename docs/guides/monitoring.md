# Monitoring Guide

This guide covers monitoring and observability in µCrystal, including metrics collection, health checks, request tracing, and logging best practices.

## Table of Contents

- [Monitoring Overview](#monitoring-overview)
- [Metrics Collection](#metrics-collection)
- [Health Checks](#health-checks)
- [Request Tracing](#request-tracing)
- [Structured Logging](#structured-logging)
- [Prometheus Integration](#prometheus-integration)
- [Distributed Tracing](#distributed-tracing)
- [Alerting](#alerting)
- [Best Practices](#best-practices)

## Monitoring Overview

µCrystal provides comprehensive monitoring capabilities:

- **Metrics**: Counters, gauges, histograms for performance tracking
- **Health Checks**: Service and dependency health monitoring
- **Tracing**: Request flow tracking across services
- **Logging**: Structured, correlated log output
- **Integration**: Prometheus, Grafana, Jaeger support

## Metrics Collection

### Built-in Metrics

µCrystal provides metrics collection through pools and gateways:

```crystal
# Pool metrics (automatically collected)
pool.connections.total{service="catalog",pool="http"}    # Total connections
pool.connections.active{service="catalog",pool="http"}   # Active connections
pool.connections.idle{service="catalog",pool="http"}     # Idle connections
pool.acquisitions.total{service="catalog",pool="http"}   # Total acquisitions
pool.acquisitions.timeouts{service="catalog",pool="http"} # Acquisition timeouts

# Gateway metrics  
gateway_requests_total                   # Total request count
gateway_cache_hits_total                 # Cache hit count
gateway_cache_misses_total               # Cache miss count
gateway_response_time_seconds            # Average response time
```

### Custom Metrics

Add application-specific metrics using the metrics collector:

```crystal
@[Micro::Service(name: "orders", version: "1.0.0")]
class OrderService
  include Micro::ServiceBase
  
  # Use a metrics collector
  @metrics : Micro::Core::MetricsCollector
  
  def initialize
    # Get metrics collector from service configuration
    @metrics = @@metrics_collector || Micro::Core::NoOpMetricsCollector.new
  end
  
  @[Micro::Method]
  def create_order(ctx : Micro::Core::Context, input : CreateOrderRequest) : Order
    order = @metrics.time("order.processing", {"type" => "create"}) do
      process_order(input)
    end
    
    # Update metrics
    @metrics.counter("orders.created", tags: {
      "payment_method" => order.payment_method,
      "shipping_type" => order.shipping_type
    })
    
    @metrics.histogram("order.value", order.total_amount, tags: {
      "currency" => order.currency
    })
    
    order
  end
  
  @[Micro::Method]
  def add_to_cart(ctx : Micro::Core::Context, req : AddToCartRequest) : Cart
    cart = get_or_create_cart(req.user_id)
    cart.add_item(req.item)
    
    # Update gauge
    @metrics.gauge("carts.active", count_active_carts.to_f)
    
    cart
  end
end
```

### Metrics Middleware

Track metrics via middleware:

```crystal
class BusinessMetricsMiddleware
  include Micro::Core::Middleware
  
  def initialize(@metrics : Micro::Core::MetricsCollector)
  end
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    # Track request size
    request_size = context.request.body.size
    @metrics.histogram("request.body_size", request_size.to_f, tags: {
      "method" => context.request.headers["X-Method"]? || "unknown"
    })
    
    # Time the request
    start_time = Time.monotonic
    
    begin
      next_middleware.try(&.call(context))
      
      # Track response size and timing
      response_size = context.response.body_bytes.size
      duration = Time.monotonic - start_time
      
      @metrics.histogram("response.body_size", response_size.to_f, tags: {
        "method" => context.request.headers["X-Method"]? || "unknown",
        "status" => context.response.status.to_s
      })
      
      @metrics.timing("request.duration", duration, tags: {
        "method" => context.request.headers["X-Method"]? || "unknown",
        "status" => context.response.status.to_s
      })
    rescue ex : Micro::BusinessError
      # Track business errors
      @metrics.counter("errors.business", tags: {
        "type" => ex.class.name.split("::").last,
        "code" => ex.code
      })
      raise ex
    rescue ex
      # Track system errors
      @metrics.counter("errors.system", tags: {
        "type" => ex.class.name.split("::").last
      })
      raise ex
    end
  end
end
```

## Health Checks

### Basic Health Check

```crystal
# Health checks are typically configured at the gateway level
gateway_config = Micro::Gateway::Config.new(
  host: "0.0.0.0",
  port: 8080,
  health_handler: ->(Nil) {
    {
      "status" => "healthy",
      "version" => "1.0.0",
      "uptime_seconds" => uptime.total_seconds,
      "services" => check_services
    }
  },
  health_path: "/health"
)

# Services can implement their own health checks
@[Micro::Service(name: "catalog", version: "1.0.0")]
class CatalogService
  include Micro::ServiceBase
  
  @[Micro::Method]
  def health_check(ctx : Micro::Core::Context, req : Empty) : HealthStatus
    HealthStatus.new(
      status: "healthy",
      version: "1.0.0",
      dependencies: check_dependencies
    )
  end
end
```

### Dependency Health Checks

```crystal
class HealthChecker
  def self.check_all : HealthStatus
    checks = {} of String => Hash(String, JSON::Any)
    
    # Check database
    checks["database"] = check_database
    
    # Check cache
    checks["redis"] = check_redis
    
    # Check external services
    checks["payment_api"] = check_payment_api
    
    # Check message broker
    checks["nats"] = check_nats
    
    # Aggregate status
    all_healthy = checks.values.all? { |c| c["status"] == "healthy" }
    
    HealthStatus.new(
      status: all_healthy ? "healthy" : "degraded",
      checks: checks,
      timestamp: Time.utc
    )
  end
  
  private def self.check_database : Hash(String, JSON::Any)
    start = Time.monotonic
    
    begin
      DB.scalar("SELECT 1")
      latency_ms = (Time.monotonic - start).total_milliseconds
      
      {
        "status" => "healthy",
        "latency_ms" => latency_ms,
        "connection_pool" => {
          "active" => DB.pool.active_connections,
          "idle" => DB.pool.idle_connections,
          "max" => DB.pool.max_connections
        }
      }
    rescue ex
      {
        "status" => "unhealthy",
        "error" => ex.message,
        "latency_ms" => (Time.monotonic - start).total_milliseconds
      }
    end
  end
  
  private def self.check_redis : Hash(String, JSON::Any)
    begin
      redis = Redis.new
      start = Time.monotonic
      redis.ping
      latency_ms = (Time.monotonic - start).total_milliseconds
      
      info = redis.info("server")
      
      {
        "status" => "healthy",
        "latency_ms" => latency_ms,
        "version" => info["redis_version"]?,
        "uptime_seconds" => info["uptime_in_seconds"]?
      }
    rescue ex
      {
        "status" => "unhealthy",
        "error" => ex.message
      }
    ensure
      redis.try(&.close)
    end
  end
end
```

### Liveness vs Readiness

```crystal
class ServiceHealth
  # Liveness: Is the service running?
  def self.liveness_check
    {
      status: "alive",
      pid: Process.pid,
      started_at: @@started_at
    }
  end
  
  # Readiness: Can the service handle requests?
  def self.readiness_check
    unless @@initialized
      return {status: "not_ready", reason: "Still initializing"}
    end
    
    unless dependencies_ready?
      return {status: "not_ready", reason: "Dependencies not available"}
    end
    
    if circuit_breaker_open?
      return {status: "not_ready", reason: "Circuit breaker open"}
    end
    
    {status: "ready"}
  end
  
  private def self.dependencies_ready? : Bool
    # Check if all required services are available
    required_services = ["database", "cache", "message_broker"]
    
    required_services.all? do |service|
      case service
      when "database"
        DB.ping rescue false
      when "cache"
        Redis.new.ping rescue false
      when "message_broker"
        NATS.connected? rescue false
      else
        true
      end
    end
  end
end
```

## Request Tracing

### Request ID Propagation

```crystal
class RequestIDMiddleware
  include Micro::Core::Middleware
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    # Get or generate request ID
    request_id = context.request.headers["X-Request-ID"]? || UUID.random.to_s
    
    # Store in context
    context.set("request_id", request_id)
    
    # Add to response
    context.response.headers["X-Request-ID"] = request_id
    
    # Set in fiber-local storage for logging
    Fiber.current.@request_id = request_id
    
    Log.context.set(request_id: request_id)
    
    next_middleware.try(&.call(context))
  end
end
```

### Trace Context Propagation

```crystal
class TraceMiddleware
  include Micro::Core::Middleware
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    # Parse incoming trace context (W3C Trace Context format)
    traceparent = context.request.headers["traceparent"]?
    tracestate = context.request.headers["tracestate"]?
    
    if traceparent
      trace_id, parent_id, flags = parse_traceparent(traceparent)
    else
      trace_id = generate_trace_id
      parent_id = nil
      flags = "00"
    end
    
    # Generate span ID for this service
    span_id = generate_span_id
    
    # Store in context
    context.set("trace_id", trace_id)
    context.set("span_id", span_id)
    context.set("parent_span_id", parent_id)
    
    # Create new traceparent for downstream
    new_traceparent = "00-#{trace_id}-#{span_id}-#{flags}"
    
    # Propagate to downstream services
    context.set("outgoing_traceparent", new_traceparent)
    
    # Add to logs
    Log.context.set(
      trace_id: trace_id,
      span_id: span_id,
      parent_span_id: parent_id
    )
    
    next_middleware.try(&.call(context))
  end
  
  private def parse_traceparent(header : String) : Tuple(String, String?, String)
    parts = header.split('-')
    return {parts[1], parts[2], parts[3]} if parts.size == 4
    {generate_trace_id, nil, "00"}
  end
  
  private def generate_trace_id : String
    Random::Secure.hex(16)
  end
  
  private def generate_span_id : String
    Random::Secure.hex(8)
  end
end
```

### Timing Breakdown

```crystal
class DetailedTimingMiddleware
  include Micro::Core::Middleware
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    total_start = Time.monotonic
    timings = {} of String => Float64
    
    # Track middleware timing
    middleware_start = Time.monotonic
    
    # Add timing hook
    context.set("timing_hook", ->(name : String, duration : Time::Span) {
      timings[name] = duration.total_milliseconds
    })
    
    next_middleware.try(&.call(context))
    
    # Calculate totals
    total_duration = Time.monotonic - total_start
    
    # Add detailed timing header
    timing_parts = timings.map { |k, v| "#{k};dur=#{v.round(2)}" }
    timing_parts << "total;dur=#{total_duration.total_milliseconds.round(2)}"
    
    context.response.headers["Server-Timing"] = timing_parts.join(", ")
    
    # Log detailed timing
    Log.info {
      {
        message: "Request completed",
        request_id: context.get?("request_id"),
        method: context.request.headers["X-Method"]?,
        total_ms: total_duration.total_milliseconds,
        breakdown: timings
      }
    }
  end
end
```

## Structured Logging

### Log Configuration

```crystal
# Configure structured JSON logging
Log.setup do |c|
  backend = Log::IOBackend.new
  formatter = Log::Formatter.new do |entry, io|
    # Build JSON output
    io.json_object do |json|
      json.field "timestamp", entry.timestamp
      json.field "severity", entry.severity.to_s
      json.field "source", entry.source
      json.field "message", entry.message
      
      # Add context fields
      if context = entry.context
        json.field "context" do
          json.object do
            context.each do |key, value|
              json.field key.to_s, value
            end
          end
        end
      end
      
      # Add exception details
      if ex = entry.exception
        json.field "exception" do
          json.object do
            json.field "type", ex.class.name
            json.field "message", ex.message || ""
            json.field "backtrace", ex.backtrace? || [] of String
          end
        end
      end
    end
    
    io.puts
  end
  
  backend.formatter = formatter
  
  c.bind "*", :info, backend
  c.bind "micro.*", :debug, backend
  c.bind "app.*", :debug, backend
end
```

### Contextual Logging

```crystal
@[Micro::Service(name: "orders", version: "1.0.0")]
class OrderService
  include Micro::ServiceBase
  
  Log = ::Log.for(self)
  
  @[Micro::Method]
  def create_order(input : CreateOrder) : Order
    Log.info { "Creating order for customer #{input.customer_id}" }
    
    # Add context that will be included in all subsequent logs
    Log.context.set(
      customer_id: input.customer_id,
      order_value: input.total_amount,
      item_count: input.items.size
    )
    
    begin
      # Validate inventory
      Log.debug { "Checking inventory for #{input.items.size} items" }
      check_inventory(input.items)
      
      # Process payment
      Log.info { "Processing payment of $#{input.total_amount}" }
      payment = process_payment(input)
      
      # Create order
      order = Order.create(input, payment)
      
      Log.info { "Order #{order.id} created successfully" }
      order
    rescue ex : InsufficientInventoryError
      Log.warn(exception: ex) { "Order failed due to inventory" }
      raise
    rescue ex : PaymentError
      Log.error(exception: ex) { "Payment processing failed" }
      raise
    rescue ex
      Log.error(exception: ex) { "Unexpected error creating order" }
      raise
    end
  end
end
```

### Audit Logging

```crystal
class AuditLogMiddleware
  include Micro::Core::Middleware
  
  Log = ::Log.for("audit")
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    start_time = Time.utc
    
    # Capture request details
    audit_entry = {
      event_type: "api_request",
      timestamp: start_time,
      request_id: context.get?("request_id"),
      user_id: context.get?("user_id"),
      client_ip: extract_client_ip(context),
      method: context.request.headers["X-Method"]?,
      path: context.request.path,
      user_agent: context.request.headers["User-Agent"]?
    }
    
    begin
      next_middleware.try(&.call(context))
      
      # Success audit
      audit_entry.merge!({
        event_type: "api_request_success",
        status: context.response.status,
        duration_ms: (Time.utc - start_time).total_milliseconds
      })
      
      Log.info { audit_entry }
    rescue ex
      # Failure audit
      audit_entry.merge!({
        event_type: "api_request_failure",
        error_type: ex.class.name,
        error_message: ex.message,
        duration_ms: (Time.utc - start_time).total_milliseconds
      })
      
      Log.error { audit_entry }
      raise
    end
  end
  
  private def extract_client_ip(context) : String?
    # Check X-Forwarded-For first
    if forwarded = context.request.headers["X-Forwarded-For"]?
      return forwarded.split(',').first.strip
    end
    
    # Fall back to X-Real-IP
    if real_ip = context.request.headers["X-Real-IP"]?
      return real_ip
    end
    
    # Finally check remote address
    context.request.headers["Remote-Addr"]?
  end
end
```

## Prometheus Integration

### Metrics Endpoint

```crystal
# Expose metrics through the gateway
gateway_config = Micro::Gateway::Config.new(
  host: "0.0.0.0",
  port: 8080,
  enable_metrics: true,
  metrics_path: "/metrics"  # Default path
)

# GET /metrics returns Prometheus exposition format, e.g.:
# TYPE gateway_requests_total counter
# gateway_requests_total 15234
# TYPE gateway_cache_hits_total counter
# gateway_cache_hits_total 42
# TYPE gateway_cache_misses_total counter
# gateway_cache_misses_total 5
# TYPE gateway_response_time_seconds gauge
# gateway_response_time_seconds 0.125

# For standalone metrics server, use HTTPMetricsServer
require "micro/stdlib/metrics/http_metrics_server"

metrics_server = Micro::Stdlib::Metrics::HTTPMetricsServer.new(
  port: 9090,
  metrics_provider: prometheus_metrics
)

spawn do
  Log.info { "Metrics server listening on :9090" }
  metrics_server.listen
end
```

### Prometheus Configuration

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'micro-services'
    consul_sd_configs:
      - server: 'consul:8500'
        services: []
    relabel_configs:
      - source_labels: [__meta_consul_service]
        target_label: service
      - source_labels: [__meta_consul_tags]
        regex: '.*,metrics,'
        action: keep
      - source_labels: [__address__]
        regex: '([^:]+):.*'
        replacement: '${1}:9090'
        target_label: __address__
```

### Custom Metrics Collector

```crystal
# Implement a custom metrics collector
class PrometheusMetricsCollector < Micro::Core::MetricsCollector
  @counters = {} of String => Float64
  @gauges = {} of String => Float64
  @histograms = {} of String => Array(Float64)
  
  def counter(name : String, value : Int64 = 1_i64, tags : Hash(String, String) = {} of String => String) : Nil
    key = build_key(name, tags)
    @counters[key] = (@counters[key]? || 0.0) + value
  end
  
  def gauge(name : String, value : Float64, tags : Hash(String, String) = {} of String => String) : Nil
    key = build_key(name, tags)
    @gauges[key] = value
  end
  
  def histogram(name : String, value : Float64, tags : Hash(String, String) = {} of String => String) : Nil
    key = build_key(name, tags)
    @histograms[key] ||= [] of Float64
    @histograms[key] << value
  end
  
  # Export metrics in Prometheus format
  def export : String
    String.build do |io|
      # Export counters
      @counters.each do |key, value|
        name, tags = parse_key(key)
        io << "# TYPE #{name} counter\n"
        io << name
        io << format_tags(tags)
        io << " " << value << "\n"
      end
      
      # Export gauges
      @gauges.each do |key, value|
        name, tags = parse_key(key)
        io << "# TYPE #{name} gauge\n"
        io << name
        io << format_tags(tags)
        io << " " << value << "\n"
      end
    end
  end
  
  private def build_key(name : String, tags : Hash(String, String)) : String
    "#{name}|#{tags.to_a.sort.map { |k, v| "#{k}=#{v}" }.join(",")}"
  end
end

# Use in service
metrics = PrometheusMetricsCollector.new
```

## Distributed Tracing

### Trace Context Propagation

µCrystal supports W3C Trace Context for distributed tracing:

```crystal
class TraceContextMiddleware
  include Micro::Core::Middleware
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    # Extract trace context from headers
    traceparent = context.request.headers["traceparent"]?
    tracestate = context.request.headers["tracestate"]?
    
    # Parse or generate trace context
    trace_id, parent_id, flags = if traceparent
      parse_traceparent(traceparent)
    else
      {generate_trace_id, nil, "00"}
    end
    
    # Generate span ID for this service
    span_id = generate_span_id
    
    # Store in context
    context.set("trace_id", trace_id)
    context.set("span_id", span_id)
    context.set("parent_span_id", parent_id) if parent_id
    
    # Add to logs
    Log.context.set(
      trace_id: trace_id,
      span_id: span_id
    )
    
    # Propagate to response for downstream
    context.response.headers["traceparent"] = "00-#{trace_id}-#{span_id}-#{flags}"
    context.response.headers["tracestate"] = tracestate if tracestate
    
    next_middleware.try(&.call(context))
  end
  
  private def parse_traceparent(header : String) : Tuple(String, String?, String)
    # Format: version-trace_id-parent_id-flags
    parts = header.split('-')
    return {parts[1], parts[2], parts[3]} if parts.size == 4
    {generate_trace_id, nil, "00"}
  end
  
  private def generate_trace_id : String
    Random::Secure.hex(16)  # 32 hex chars = 128 bits
  end
  
  private def generate_span_id : String
    Random::Secure.hex(8)   # 16 hex chars = 64 bits
  end
end
```

### Tracing Service Calls

```crystal
# Client automatically propagates trace context
client = Micro::Stdlib::Client.new(options)

# Trace context is automatically propagated via headers
response = client.call(
  service: "catalog",
  method: "get_product",
  body: {"id" => product_id}.to_json.to_slice,
  headers: HTTP::Headers{
    # These are automatically added from context:
    # "traceparent" => "00-#{trace_id}-#{span_id}-00"
    # "tracestate" => "vendor1=value1"
  }
)

# For custom tracing integration
class TracingClientMiddleware
  include Micro::Core::Middleware
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    # Extract trace info from current context
    if trace_id = context.get?("trace_id", String)
      span_id = context.get("span_id", String)
      
      # Add to outgoing request headers
      context.request.headers["traceparent"] = "00-#{trace_id}-#{span_id}-00"
    end
    
    # Time the call
    start_time = Time.monotonic
    
    begin
      next_middleware.try(&.call(context))
      
      duration = Time.monotonic - start_time
      
      # Log trace info
      Log.info { {
        message: "Service call completed",
        trace_id: trace_id,
        span_id: span_id,
        duration_ms: duration.total_milliseconds,
        service: context.request.service,
        method: context.request.endpoint
      } }
    rescue ex
      Log.error(exception: ex) { {
        message: "Service call failed",
        trace_id: trace_id,
        span_id: span_id
      } }
      raise
    end
  end
end
```

## Alerting

### Alert Rules

```crystal
class AlertManager
  struct AlertRule
    getter name : String
    getter condition : Proc(Bool)
    getter message : Proc(String)
    getter severity : Severity
    getter cooldown : Time::Span
    
    enum Severity
      Info
      Warning
      Critical
    end
  end
  
  def initialize
    @rules = [] of AlertRule
    @last_fired = {} of String => Time
  end
  
  def add_rule(name : String, severity : AlertRule::Severity, 
               cooldown : Time::Span = 5.minutes, &condition : -> Bool)
    rule = AlertRule.new(
      name: name,
      condition: condition,
      message: ->{
        "Alert: #{name} triggered at #{Time.utc}"
      },
      severity: severity,
      cooldown: cooldown
    )
    @rules << rule
  end
  
  def check_all
    @rules.each do |rule|
      check_rule(rule)
    end
  end
  
  private def check_rule(rule : AlertRule)
    # Check cooldown
    if last = @last_fired[rule.name]?
      return if Time.utc - last < rule.cooldown
    end
    
    # Evaluate condition
    if rule.condition.call
      fire_alert(rule)
      @last_fired[rule.name] = Time.utc
    end
  end
  
  private def fire_alert(rule : AlertRule)
    # Log alert
    Log.for("alerts").warn { 
      {
        alert: rule.name,
        severity: rule.severity.to_s,
        message: rule.message.call
      }
    }
    
    # Send notifications based on severity
    case rule.severity
    when .critical?
      send_pagerduty(rule)
      send_slack(rule, channel: "#alerts-critical")
    when .warning?
      send_slack(rule, channel: "#alerts-warning")
    when .info?
      send_slack(rule, channel: "#alerts-info")
    end
  end
end

# Configure alerts
alerts = AlertManager.new

alerts.add_rule("high_error_rate", :critical) do
  error_rate = Micro::Metrics.query("rate(requests_total{status=~'5..'}[5m])")
  total_rate = Micro::Metrics.query("rate(requests_total[5m])")
  
  (error_rate / total_rate) > 0.05  # 5% error rate
end

alerts.add_rule("high_response_time", :warning) do
  p95_latency = Micro::Metrics.query(
    "histogram_quantile(0.95, rate(request_duration_seconds_bucket[5m]))"
  )
  
  p95_latency > 1.0  # 1 second
end

alerts.add_rule("low_disk_space", :critical) do
  disk_free = Micro::Metrics.query("node_filesystem_avail_bytes")
  disk_total = Micro::Metrics.query("node_filesystem_size_bytes")
  
  (disk_free / disk_total) < 0.1  # Less than 10% free
end

# Run alert checks
spawn do
  loop do
    alerts.check_all
    sleep 30.seconds
  end
end
```

### Alert Notifications

```crystal
class NotificationService
  def send_slack(message : String, channel : String, severity : String)
    webhook_url = ENV["SLACK_WEBHOOK_URL"]
    
    payload = {
      channel: channel,
      username: "Monitoring Bot",
      icon_emoji: severity_emoji(severity),
      attachments: [{
        color: severity_color(severity),
        title: "Alert: #{severity}",
        text: message,
        timestamp: Time.utc.to_unix,
        fields: [
          {
            title: "Service",
            value: ENV["SERVICE_NAME"]?,
            short: true
          },
          {
            title: "Environment", 
            value: ENV["ENVIRONMENT"]?,
            short: true
          }
        ]
      }]
    }
    
    HTTP::Client.post(webhook_url, headers: HTTP::Headers{
      "Content-Type" => "application/json"
    }, body: payload.to_json)
  end
  
  def send_pagerduty(incident : Incident)
    client = HTTP::Client.new("events.pagerduty.com", tls: true)
    
    event = {
      routing_key: ENV["PAGERDUTY_ROUTING_KEY"],
      event_action: "trigger",
      dedup_key: incident.key,
      payload: {
        summary: incident.summary,
        severity: incident.severity,
        source: ENV["SERVICE_NAME"],
        custom_details: incident.details
      }
    }
    
    response = client.post("/v2/enqueue", headers: HTTP::Headers{
      "Content-Type" => "application/json"
    }, body: event.to_json)
    
    unless response.success?
      Log.error { "Failed to send PagerDuty alert: #{response.status}" }
    end
  ensure
    client.try(&.close)
  end
  
  private def severity_color(severity : String) : String
    case severity.downcase
    when "critical" then "danger"
    when "warning" then "warning"
    when "info" then "good"
    else "default"
    end
  end
  
  private def severity_emoji(severity : String) : String
    case severity.downcase
    when "critical" then ":rotating_light:"
    when "warning" then ":warning:"
    when "info" then ":information_source:"
    else ":question:"
    end
  end
end
```

## Best Practices

### 1. Use Consistent Naming

Follow naming conventions for metrics:

```crystal
# Good metric names
micro_requests_total            # Counter with _total suffix
micro_request_duration_seconds  # Duration with unit suffix
micro_connections_active        # Gauge without suffix
micro_memory_usage_bytes        # Size with unit suffix

# Include relevant labels
Micro::Metrics.counter(
  "orders_total",
  labels: {
    "status" => "completed",      # Order status
    "payment_method" => "card",   # Payment type
    "region" => "us-east-1"       # Geographic region
  }
)
```

### 2. Avoid High Cardinality

Limit label values to prevent metric explosion:

```crystal
# Bad: High cardinality
@metrics.increment("user_requests", labels: {
  "user_id" => user.id,  # Millions of unique values!
  "session_id" => session.id  # Even more unique values!
})

# Good: Bounded cardinality
@metrics.increment("user_requests", labels: {
  "user_type" => user.type,  # Limited set: free, pro, enterprise
  "country" => user.country_code  # ~200 possible values
})

# For user-specific metrics, use aggregation
@metrics.histogram("request_duration", duration, labels: {
  "endpoint" => "/api/orders",
  "method" => "POST",
  "status_code" => "200"
})
```

### 3. Monitor SLIs and SLOs

Track Service Level Indicators:

```crystal
class SLOMonitor
  def initialize
    @error_budget = Micro::Metrics.gauge(
      "slo_error_budget_remaining",
      "Remaining error budget as percentage"
    )
  end
  
  def calculate_slos
    # Availability SLO: 99.9%
    availability = calculate_availability
    availability_budget = (availability - 0.999) * 100
    @error_budget.set(availability_budget, labels: {"slo" => "availability"})
    
    # Latency SLO: 95% of requests < 200ms
    latency_compliance = calculate_latency_compliance
    latency_budget = (latency_compliance - 0.95) * 100
    @error_budget.set(latency_budget, labels: {"slo" => "latency"})
    
    # Error rate SLO: < 0.1%
    error_rate = calculate_error_rate
    error_budget = (0.001 - error_rate) * 1000
    @error_budget.set(error_budget, labels: {"slo" => "errors"})
  end
end
```

### 4. Structured Logging

Use consistent log structure:

```crystal
# Define log schema
struct LogEntry
  include JSON::Serializable
  
  getter timestamp : Time
  getter level : String
  getter service : String
  getter version : String
  getter message : String
  getter request_id : String?
  getter user_id : String?
  getter duration_ms : Float64?
  getter error : ErrorInfo?
  
  struct ErrorInfo
    include JSON::Serializable
    getter type : String
    getter message : String
    getter stacktrace : Array(String)?
  end
end

# Use structured logging
Log.info {
  LogEntry.new(
    timestamp: Time.utc,
    level: "INFO",
    service: "orders",
    version: "1.0.0",
    message: "Order processed successfully",
    request_id: context.get("request_id").as(String),
    user_id: context.get("user_id").as(String),
    duration_ms: processing_time.total_milliseconds
  )
}
```

### 5. Dashboard Best Practices

Create effective dashboards:

```crystal
# Export dashboard configuration
class DashboardExporter
  def export_service_dashboard(service_name : String)
    {
      title: "#{service_name} Service Dashboard",
      panels: [
        # Request rate
        {
          title: "Request Rate",
          query: "rate(micro_requests_total{service=\"#{service_name}\"}[5m])",
          type: "graph"
        },
        # Error rate
        {
          title: "Error Rate",
          query: "rate(micro_requests_total{service=\"#{service_name}\",status=~\"5..\"}[5m])",
          type: "graph",
          alert: {
            condition: "> 0.05",
            for: "5m",
            severity: "warning"
          }
        },
        # Response time
        {
          title: "Response Time (p50, p95, p99)",
          queries: [
            "histogram_quantile(0.5, rate(micro_request_duration_seconds_bucket{service=\"#{service_name}\"}[5m]))",
            "histogram_quantile(0.95, rate(micro_request_duration_seconds_bucket{service=\"#{service_name}\"}[5m]))",
            "histogram_quantile(0.99, rate(micro_request_duration_seconds_bucket{service=\"#{service_name}\"}[5m]))"
          ],
          type: "graph"
        },
        # Active connections
        {
          title: "Active Connections",
          query: "micro_transport_connections_active{service=\"#{service_name}\"}",
          type: "gauge"
        }
      ]
    }
  end
end
```

## Next Steps

- Set up [Testing](testing.md) with monitoring verification
- Configure [API Gateway](api-gateway.md) monitoring
- Review [Service Development](service-development.md) with observability
- Implement [Authentication & Security](auth-security.md) monitoring