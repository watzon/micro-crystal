# Client Communication Guide

This guide covers how to create clients and communicate between services in µCrystal, including RPC calls, streaming, timeouts, and error handling.

## Table of Contents

- [Creating Clients](#creating-clients)
- [Making RPC Calls](#making-rpc-calls)
- [Typed Clients](#typed-clients)
- [Service Discovery](#service-discovery)
- [Timeouts and Retries](#timeouts-and-retries)
- [Error Handling](#error-handling)
- [Streaming](#streaming)
- [Advanced Patterns](#advanced-patterns)

## Creating Clients

### Basic Client

The simplest way to create a client is using the default transport:

```crystal
require "micro"

# Create a client with default HTTP transport
client = Micro.client

# Make a call
response = client.call(
  service: "catalog",
  method: "list_products",
  body: Bytes.empty
)
products = Array(Product).from_json(response.body)
```

### Client with Custom Configuration

```crystal
# Create client with specific transport
transport = Micro::Stdlib::Transports::HTTPTransport.new(
  Micro::Core::Transport::Options.new
)
client = Micro::Stdlib::Client.new(transport)
```

### Client from Service Context

Services can access a pre-configured client:

```crystal
@[Micro::Service(name: "orders", version: "1.0.0")]
class OrderService
  include Micro::ServiceBase
  
  @[Micro::Method]
  def create_order(input : CreateOrder) : Order
    # Use the service's client to call catalog service
    response = client.call(
      service: "catalog",
      method: "get_product",
      body: %("#{input.product_id}").to_slice
    )
    
    product = Product.from_json(response.body)
    # Create order...
  end
end
```

## Making RPC Calls

### Basic Call Syntax

```crystal
response = client.call(
  service: "catalog",              # Target service name
  method: "get_product",           # Method to call
  body: %("product-123").to_slice  # Request body as bytes
)

# Check response
if response.status < 400
  product = Product.from_json(response.body)
else
  error = Error.from_json(response.body)
  raise "Service error: #{error.message}"
end
```

### Call with Headers

```crystal
headers = HTTP::Headers.new
headers["X-User-ID"] = current_user.id
headers["X-Trace-ID"] = trace_id

response = client.call(
  service: "orders",
  method: "list_orders",
  headers: headers,
  body: Bytes.empty
)
```

### JSON Helper Method

For convenience when working with JSON, you can serialize your payload:

```crystal
# Serialize payload to JSON bytes
payload = {
  name: "New Product",
  price: 29.99,
  category: "electronics"
}

response = client.call(
  service: "catalog",
  method: "create_product",
  body: payload.to_json.to_slice
)

# Response is raw - parse as needed
product = Product.from_json(response.body)
```

## Typed Clients

### Generating Client Stubs

Use the `generate_client_for` macro to generate type-safe client stubs:

```crystal
# First, define your service with annotations
@[Micro::Service(name: "catalog", version: "1.0.0")]
class CatalogService
  include Micro::ServiceBase
  
  @[Micro::Method]
  def list_products : Array(Product)
    # Implementation...
  end
  
  @[Micro::Method]
  def get_product(id : String) : Product?
    # Implementation...
  end
end

# Then create a typed client
class CatalogClient < Micro::Stdlib::TypedClient
  generate_client_for(CatalogService)
end

# Use the generated client
transport = Micro::Stdlib::Transports::HTTPTransport.new
client = CatalogClient.new(transport, "localhost:8080")
products = client.list_products  # Returns Array(Product)
product = client.get_product("123")  # Returns Product?
```

### Custom Client Implementation

For more control, implement a custom typed client:

```crystal
class CatalogClient < Micro::Stdlib::TypedClient
  def initialize(client : Micro::Stdlib::Client? = nil)
    super(client || Micro.client, "catalog")
  end
  
  def list_products : Array(Product)
    response = call_json("list_products")
    Array(Product).from_json(response.body)
  end
  
  def get_product(id : String) : Product?
    response = call_json("get_product", id)
    return nil if response.status == 404
    Product.from_json(response.body)
  end
  
  def search_products(query : String, limit : Int32 = 10) : Array(Product)
    response = call_json("search_products", {
      query: query,
      limit: limit
    })
    Array(Product).from_json(response.body)
  end
end
```

## Service Discovery

### Consul Registry

When using Consul for service discovery:

```crystal
# Client automatically discovers services via registry
registry = Micro::Stdlib::Registries::ConsulRegistry.new(
  Micro::Core::Registry::Options.new(
    type: "consul",
    addresses: [ENV["CONSUL_ADDR"]]
  )
)

transport = Micro::Stdlib::Transports::HTTPTransport.new
client = Micro::Stdlib::DiscoveryClient.new(transport, registry)

# No need to specify addresses - discovery happens automatically
response = client.call(
  service: "catalog",
  method: "list_products",
  body: Bytes.empty
)
```

### Memory Registry (Development)

For single-process development:

```crystal
registry = Micro::Stdlib::Registries::MemoryRegistry.new(
  Micro::Core::Registry::Options.new(type: "memory")
)

# Services register themselves
catalog_options = Micro::Core::Service::Options.new(
  name: "catalog",
  version: "1.0.0",
  registry: registry
)
CatalogService.run(catalog_options)

order_options = Micro::Core::Service::Options.new(
  name: "orders",
  version: "1.0.0",
  registry: registry
)
OrderService.run(order_options)

# Client discovers via registry
transport = Micro::Stdlib::Transports::HTTPTransport.new
client = Micro::Stdlib::DiscoveryClient.new(transport, registry)
```

### Manual Service Resolution

```crystal
# When using DiscoveryClient, service resolution is automatic
# But you can also manually resolve services if needed:

registry = Micro::Stdlib::Registries::ConsulRegistry.new(
  Micro::Core::Registry::Options.new(
    type: "consul", 
    addresses: [ENV["CONSUL_ADDR"]]
  )
)

# Get service instances from registry
services = registry.get_service("catalog", "*")  # "*" for any version

# Get all nodes from services
nodes = services.flat_map(&.nodes)

# Select a node using a selector
selector = Micro::Core::RoundRobinSelector.new
node = selector.select(nodes)

# Use the node's address
transport = Micro::Stdlib::Transports::HTTPTransport.new
client = Micro::Stdlib::Client.new(transport)

# Override the default address behavior by using a custom request
request = Micro::Core::TransportRequest.new(
  service: "catalog",
  method: "list_products",
  body: Bytes.empty,
  headers: HTTP::Headers.new
)
# Note: In the current implementation, you would need to configure the client
# or transport with the specific node address
```

## Timeouts and Retries

### Request Timeouts

```crystal
# Per-request timeout using CallOptions
opts = Micro::Core::CallOptions.new(
  timeout: 60.seconds  # Override default timeout
)

response = client.call(
  service: "slow-service",
  method: "heavy_operation",
  body: Bytes.empty,
  opts: opts
)

# Note: Default timeout is 30 seconds per CallOptions
```

### Implementing Retries

```crystal
class ResilientClient
  def initialize(@client : Micro::Stdlib::Client)
  end
  
  def call_with_retry(service : String, method : String, body : Bytes = Bytes.empty,
                      max_retries : Int32 = 3, backoff : Time::Span = 1.second)
    retries = 0
    
    loop do
      begin
        return @client.call(service, method, body: body)
      rescue ex : IO::TimeoutError | Micro::Core::ServiceUnavailableError
        retries += 1
        if retries >= max_retries
          raise ex
        end
        
        # Exponential backoff
        sleep(backoff * retries)
      end
    end
  end
end
```

### Circuit Breaker Pattern

```crystal
class CircuitBreakerClient
  enum State
    Closed
    Open
    HalfOpen
  end
  
  def initialize(@client : Micro::Stdlib::Client, 
                 @failure_threshold : Int32 = 5,
                 @reset_timeout : Time::Span = 30.seconds)
    @state = State::Closed
    @failure_count = 0
    @last_failure_time = Time.utc
  end
  
  def call(service : String, method : String, body : Bytes = Bytes.empty)
    case @state
    when State::Open
      if Time.utc - @last_failure_time > @reset_timeout
        @state = State::HalfOpen
      else
        raise Micro::Core::ServiceUnavailableError.new("Circuit breaker open")
      end
    end
    
    begin
      response = @client.call(service, method, body: body)
      
      # Reset on success
      if @state == State::HalfOpen
        @state = State::Closed
        @failure_count = 0
      end
      
      response
    rescue ex
      @failure_count += 1
      @last_failure_time = Time.utc
      
      if @failure_count >= @failure_threshold
        @state = State::Open
      end
      
      raise ex
    end
  end
end
```

## Error Handling

### Standard Error Responses

µCrystal services return structured errors:

```crystal
begin
  response = client.call(
    service: "catalog",
    method: "get_product",
    body: %("invalid-id").to_slice
  )
  
  if response.status >= 400
    # Parse error response (assumes JSON error format)
    error_data = JSON.parse(response.body)
    error_message = error_data["error"]?.try(&.as_s) || "Unknown error"
    
    case response.status
    when 404
      Log.warn { "Product not found: #{error_message}" }
      return nil
    when 400
      raise ArgumentError.new(error_message)
    else
      raise "Service error: #{error_message}"
    end
  end
  
  Product.from_json(response.body)
rescue ex : Micro::Core::TransportError
  Log.error { "Transport error: #{ex.message}" }
  raise
end
```

### Typed Error Handling

With typed clients:

```crystal
class CatalogClient < Micro::Stdlib::TypedClient
  generate_client_for(CatalogService)
  
  class ProductNotFoundError < Exception; end
  class InvalidProductError < Exception; end
  
  # Override generated method to add custom error handling
  def get_product(id : String) : Product?
    request = Micro::Core::Request.new(
      service: service_name,
      endpoint: "get_product",
      body: id.to_json.to_slice,
      content_type: "application/json"
    )
    
    response = call(request)
    
    case response.status
    when 200
      Product.from_json(response.body)
    when 404
      nil  # Return nil for not found
    when 400
      error_data = JSON.parse(response.body)
      error_message = error_data["error"]?.try(&.as_s) || "Invalid request"
      raise InvalidProductError.new(error_message)
    else
      raise "Unexpected response: #{response.status}"
    end
  end
end
```

## Streaming

**Note**: Streaming support is not yet implemented in the HTTP transport. This feature is planned for a future release.

## Advanced Patterns

### Request Context Propagation

Propagate context (like trace IDs) across service calls:

```crystal
class ContextAwareClient
  def initialize(@client : Micro::Stdlib::Client)
  end
  
  def call_with_context(context : Micro::Core::Context, service : String, 
                        method : String, body : Bytes = Bytes.empty)
    # Create call options with headers from context
    opts = Micro::Core::CallOptions.new(
      headers: HTTP::Headers.new
    )
    
    # Propagate trace ID
    if trace_id = context.get?("trace_id", String)
      opts.headers["X-Trace-ID"] = trace_id
    end
    
    # Propagate user context
    if user_id = context.get?("user_id", String)
      opts.headers["X-User-ID"] = user_id
    end
    
    @client.call(service, method, body: body, opts: opts)
  end
end
```

### Batch Operations

Implement batch calls for efficiency:

```crystal
class BatchClient
  def initialize(@client : Micro::Stdlib::Client)
  end
  
  def batch_get_products(ids : Array(String)) : Array(Product?)
    # Could be optimized with a batch endpoint
    channel = Channel(Tuple(Int32, Product?)).new
    
    ids.each_with_index do |id, index|
      spawn do
        begin
          response = @client.call(
            service: "catalog",
            method: "get_product",
            body: id.to_json.to_slice
          )
          product = response.status == 200 ? Product.from_json(response.body) : nil
          channel.send({index, product})
        rescue
          channel.send({index, nil})
        end
      end
    end
    
    # Collect results in order
    results = Array(Product?).new(ids.size, nil)
    ids.size.times do
      index, product = channel.receive
      results[index] = product
    end
    
    results
  end
end
```

### Health Checking

Monitor service health before making calls:

```crystal
class HealthAwareClient
  def initialize(@client : Micro::Stdlib::Client)
    @health_cache = {} of String => HealthStatus
    @cache_duration = 30.seconds
  end
  
  struct HealthStatus
    getter healthy : Bool
    getter checked_at : Time
    
    def initialize(@healthy, @checked_at)
    end
    
    def expired?(duration : Time::Span) : Bool
      Time.utc - checked_at > duration
    end
  end
  
  def call_if_healthy(service : String, method : String, body : Bytes = Bytes.empty)
    unless service_healthy?(service)
      raise Micro::Core::ServiceUnavailableError.new("#{service} is unhealthy")
    end
    
    @client.call(service, method, body: body)
  end
  
  private def service_healthy?(service : String) : Bool
    status = @health_cache[service]?
    
    if status.nil? || status.expired?(@cache_duration)
      # Check health
      begin
        opts = Micro::Core::CallOptions.new(timeout: 5.seconds)
        response = @client.call(
          service: service,
          method: "health",
          body: Bytes.empty,
          opts: opts
        )
        healthy = response.status == 200
      rescue
        healthy = false
      end
      
      @health_cache[service] = HealthStatus.new(healthy, Time.utc)
      healthy
    else
      status.healthy
    end
  end
end
```

### Load Balancing Strategies

Implement custom load balancing:

```crystal
class WeightedClient
  def initialize(@registry : Micro::Core::Registry::Base,
                 @weights : Hash(String, Float64) = {} of String => Float64)
    @transport = Micro::Stdlib::Transports::HTTPTransport.new
  end
  
  def call(service : String, method : String, body : Bytes = Bytes.empty)
    # Get service instances
    services = @registry.get_service(service, "*")
    nodes = services.flat_map(&.nodes)
    
    # Select node based on weights
    node = select_weighted(nodes)
    
    # Create client for specific node address
    client = Micro::Stdlib::Client.new(@transport)
    # Note: Current implementation would need to handle node.address
    # This is a conceptual example
    
    client.call(
      service: service,
      method: method,
      body: body
    )
  end
  
  private def select_weighted(nodes : Array(Micro::Core::Registry::Node))
    # Simple weighted random selection
    total_weight = nodes.sum do |node|
      @weights[node.id]? || 1.0
    end
    
    random = Random.rand(total_weight)
    current = 0.0
    
    nodes.each do |node|
      current += @weights[node.id]? || 1.0
      return node if current >= random
    end
    
    nodes.last  # Fallback
  end
end
```

## Best Practices

### 1. Use Typed Clients

Prefer typed clients for better compile-time safety:

```crystal
# Good: Type-safe
catalog = CatalogClient.new
products = catalog.list_products  # Compiler knows this returns Array(Product)

# Avoid: Untyped
response = client.call("catalog", "list_products")
products = JSON.parse(response.body)  # No compile-time safety
```

### 2. Handle All Error Cases

Always handle both transport and application errors:

```crystal
begin
  product = catalog_client.get_product(id)
rescue ex : Micro::Core::TransportError
  # Network/transport issues
  Log.error { "Failed to reach catalog service: #{ex.message}" }
  return default_product
rescue ex : CatalogClient::ProductNotFoundError
  # Expected application error
  return nil
rescue ex
  # Unexpected errors
  Log.error(exception: ex) { "Unexpected error getting product" }
  raise
end
```

### 3. Set Appropriate Timeouts

Configure timeouts based on operation type:

```crystal
# Fast queries
opts = Micro::Core::CallOptions.new(timeout: 5.seconds)
response = client.call(
  service: "catalog",
  method: "search_products", 
  body: query.to_json.to_slice,
  opts: opts
)

# Slow operations
opts = Micro::Core::CallOptions.new(timeout: 5.minutes)
response = client.call(
  service: "analytics",
  method: "generate_report",
  body: params.to_json.to_slice,
  opts: opts
)

# Real-time operations
opts = Micro::Core::CallOptions.new(timeout: 100.milliseconds)
response = client.call(
  service: "streaming",
  method: "get_update",
  body: Bytes.empty,
  opts: opts
)
```

### 4. Implement Graceful Degradation

Provide fallbacks for non-critical services:

```crystal
def get_product_with_recommendations(id : String, client : Micro::Stdlib::Client)
  # Get primary data
  product_response = client.call(
    service: "catalog",
    method: "get_product",
    body: id.to_json.to_slice
  )
  product = Product.from_json(product_response.body)
  
  # Recommendations are nice-to-have
  recommendations = begin
    opts = Micro::Core::CallOptions.new(timeout: 2.seconds)
    rec_response = client.call(
      service: "recommendations",
      method: "get_similar",
      body: id.to_json.to_slice,
      opts: opts
    )
    Array(Product).from_json(rec_response.body)
  rescue ex
    Log.warn { "Failed to get recommendations: #{ex.message}" }
    [] of Product  # Empty fallback
  end
  
  {product: product, recommendations: recommendations}
end
```

### 5. Monitor Client Metrics

Track client-side metrics:

```crystal
class MetricsClient
  def initialize(@client : Micro::Stdlib::Client, @metrics : MetricsCollector)
  end
  
  def call(service : String, method : String, body : Bytes = Bytes.empty)
    start = Time.monotonic
    
    begin
      response = @client.call(service, method, body: body)
      @metrics.record_call(service, method, response.status, Time.monotonic - start)
      response
    rescue ex
      @metrics.record_error(service, method, ex.class.name, Time.monotonic - start)
      raise
    end
  end
end
```

## Next Steps

- Learn about [Middleware](middleware.md) for cross-cutting concerns
- Implement [Authentication & Security](auth-security.md) for secure communication
- Set up [Monitoring](monitoring.md) for client metrics
- Explore [Testing](testing.md) patterns for client code