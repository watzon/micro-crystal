# µCrystal API Reference

## Table of contents

- [Micro module](#micro-module)
- [Factory methods](#factory-methods)
- [Client API](#client-api)
- [Gateway builder DSL](#gateway-builder-dsl)
- [Type aliases](#type-aliases)

This document provides a complete reference for the high-level API of µCrystal, including module methods, factory methods, client API, and the Gateway Builder DSL.

## Micro Module

The main `Micro` module provides the entry point for creating services, clients, and accessing factory methods.

### Service Creation

#### `Micro.new_service(name, version, &block)`

Creates a new service with configuration block.

**Parameters:**
- `name` (String) - Service name
- `version` (String) - Service version (default: "latest")
- `&block` - Configuration block receiving the service instance

**Returns:** `Core::Service::Base`

**Example:**
```crystal
service = Micro.new_service("greeter", "1.0.0") do |svc|
  svc.handle("hello") do |ctx|
    name = ctx.request.params["name"]? || "World"
    ctx.response.body = {message: "Hello #{name}!"}.to_json
  end
end

service.run
```

**Related:** `ServiceOptions`, `@[Micro::Service]`

#### `Micro.new_service(options)`

Creates a new service with pre-configured options.

**Parameters:**
- `options` (ServiceOptions) - Service configuration

**Returns:** `Core::Service::Base`

**Example:**
```crystal
options = Micro::ServiceOptions.new(
  name: "api-service",
  version: "2.0.0",
  transport: Micro::Transports.http,
  registry: Micro::Registries.consul
)

service = Micro.new_service(options)
```

**Related:** `ServiceOptions` configuration

### Client Creation

#### `Micro.new_client(transport?)`

Creates a new RPC client.

**Parameters:**
- `transport` (Core::Transport?) - Optional transport (defaults to HTTP)

**Returns:** `Core::Client`

**Example:**
```crystal
# Default HTTP transport
client = Micro.new_client

# Custom transport
transport = Micro::Transports.websocket
client = Micro.new_client(transport)

# Make a call
response = client.call("greeter", "hello", {name: "Alice"}.to_json.to_slice)
```

**Related:** `Micro.client`, Transport configuration

#### `Micro.client(transport?)`

Alias for `new_client` with shorter name.

**Parameters:** Same as `new_client`

**Returns:** `Core::Client`

**Example:**
```crystal
client = Micro.client
response = client.call("service", "method", payload)
```

### Codec Registration

#### `Micro.register_codec(codec)`

Registers a codec with the global codec registry.

**Parameters:**
- `codec` (Core::Codec) - Codec implementation

**Example:**
```crystal
custom_codec = MyCustomCodec.new
Micro.register_codec(custom_codec)
```

**Related:** Codec factories

## Factory Methods

µCrystal provides factory methods for creating common components without directly instantiating classes.

### Transport Factories

Located in `Micro::Transports` module.

#### `Transports.http(options?)`

Creates an HTTP transport.

**Parameters:**
- `options` (Core::Transport::Options) - Transport options

**Returns:** `Core::Transport`

**Example:**
```crystal
transport = Micro::Transports.http(
  Core::Transport::Options.new(
    address: "0.0.0.0:8080",
    secure: true,
    timeout: 60.seconds
  )
)
```

**Related:** Transport configuration, TLS options

#### `Transports.websocket(options?)`

Creates a WebSocket transport.

**Parameters:**
- `options` (Core::Transport::Options) - Transport options

**Returns:** `Core::Transport`

**Example:**
```crystal
transport = Micro::Transports.websocket(
  Core::Transport::Options.new(
    address: "0.0.0.0:8081"
  )
)
```

**Related:** Streaming, bidirectional communication

#### `Transports.loopback(options?)`

Creates an in-process loopback transport for testing.

**Parameters:**
- `options` (Core::Transport::Options) - Transport options

**Returns:** `Core::Transport`

**Example:**
```crystal
# For testing without network
transport = Micro::Transports.loopback
```

**Related:** Testing, service harness

### Codec Factories

Located in `Micro::Codecs` module.

#### `Codecs.json`

Creates a JSON codec.

**Returns:** `Core::Codec`

**Example:**
```crystal
codec = Micro::Codecs.json
service_options.codec = codec
```

**Related:** JSON serialization

#### `Codecs.msgpack`

Creates a MessagePack codec.

**Returns:** `Core::Codec`

**Example:**
```crystal
codec = Micro::Codecs.msgpack
# More efficient binary serialization
```

**Related:** Binary protocols, performance

### Registry Factories

Located in `Micro::Registries` module.

#### `Registries.memory`

Creates an in-memory registry for single-process use.

**Returns:** `Core::Registry::Base`

**Example:**
```crystal
registry = Micro::Registries.memory
# Perfect for development and testing
```

**Related:** Development mode, testing

#### `Registries.consul(options?)`

Creates a Consul registry for distributed systems.

**Parameters:**
- `options` (Core::Registry::Options) - Registry options

**Returns:** `Core::Registry::Base`

**Example:**
```crystal
registry = Micro::Registries.consul(
  Core::Registry::Options.new(
    addresses: ["consul.service.consul:8500"],
    timeout: 5.seconds
  )
)
```

**Related:** Service discovery, health checks

### Broker Factories

Located in `Micro::Brokers` module.

#### `Brokers.memory`

Creates an in-memory message broker.

**Returns:** `Core::Broker::Base`

**Example:**
```crystal
broker = Micro::Brokers.memory
# For single-process pub/sub
```

**Related:** Event handling, pub/sub

#### `Brokers.nats(url?)`

Creates a NATS message broker.

**Parameters:**
- `url` (String?) - NATS server URL (defaults to ENV["NATS_URL"])

**Returns:** `Core::Broker::Base`

**Example:**
```crystal
# Explicit URL
broker = Micro::Brokers.nats("nats://localhost:4222")

# Use environment variable
ENV["NATS_URL"] = "nats://nats.example.com:4222"
broker = Micro::Brokers.nats
```

**Related:** Distributed messaging, event streaming

## Client API

The client provides methods for calling remote services.

### `Client#call(request)`

Makes an RPC call with a transport request.

**Parameters:**
- `request` (TransportRequest) - Complete request object

**Returns:** `TransportResponse`

**Example:**
```crystal
request = Micro::TransportRequest.new(
  service: "user-service",
  method: "get_user",
  body: {id: 123}.to_json.to_slice,
  timeout: 10.seconds
)

response = client.call(request)
```

### `Client#call(service, method, body, opts?)`

Makes an RPC call with individual parameters.

**Parameters:**
- `service` (String) - Target service name
- `method` (String) - Target method name
- `body` (Bytes) - Request body
- `opts` (CallOptions?) - Call options

**Returns:** `TransportResponse`

**Example:**
```crystal
response = client.call(
  "user-service",
  "create_user",
  user_data.to_json.to_slice,
  Micro::CallOptions.new(
    timeout: 5.seconds,
    retry_count: 3
  )
)

if response.success?
  user = User.from_json(String.new(response.body))
else
  puts "Error: #{response.error}"
end
```

**Related:** `CallOptions`, error handling

### `Client#stream(service, method, opts?)`

Opens a bidirectional streaming connection.

**Parameters:**
- `service` (String) - Target service name
- `method` (String) - Target method name
- `opts` (CallOptions?) - Call options

**Returns:** `Stream`

**Example:**
```crystal
stream = client.stream("chat-service", "chat")

# Send messages
spawn do
  loop do
    message = gets
    break unless message
    stream.send(message.to_slice)
  end
  stream.close_send
end

# Receive messages
loop do
  data = stream.receive
  break if stream.closed?
  puts String.new(data)
end
```

**Related:** Streaming, WebSocket transport

## Gateway Builder DSL

The Gateway provides a DSL for building API gateways declaratively.

### Gateway Creation

#### `Micro::Gateway.build(&block)`

Builds a gateway using the DSL.

**Returns:** `APIGateway`

**Example:**
```crystal
gateway = Micro::Gateway.build do
  name "my-gateway"
  version "1.0.0"
  host "0.0.0.0"
  port 8080
  
  # Configure components...
end

gateway.run
```

### Basic Configuration

#### `name(value)`

Sets the gateway name.

**Parameters:**
- `value` (String) - Gateway name

#### `version(value)`

Sets the gateway version.

**Parameters:**
- `value` (String) - Gateway version

#### `host(value)`

Sets the bind host.

**Parameters:**
- `value` (String) - Host address

#### `port(value)`

Sets the bind port.

**Parameters:**
- `value` (Int32) - Port number

### Registry Configuration

#### `registry(type, &block)`

Configures the service registry.

**Parameters:**
- `type` (Symbol) - Registry type (:consul, :memory)
- `&block` - Configuration block

**Example:**
```crystal
registry :consul do
  address "consul.service.consul:8500"
  datacenter "dc1"
  token ENV["CONSUL_TOKEN"]
  scheme "https" # optional, defaults to "http"
end
```

#### `registry(instance)`

Sets a pre-configured registry instance.

**Parameters:**
- `instance` (Core::Registry::Base) - Registry instance

### Service Configuration

#### `service(name, &block)`

Configures a backend service.

**Parameters:**
- `name` (String) - Service name
- `&block` - Service configuration block

**Example:**
```crystal
service "user-service" do
  version "1.0.0"
  prefix "/api/users"
  timeout 5.seconds
  
  expose :list, :get, :create, :update
  block :delete
  
  require_auth true
  require_role :user
  
  circuit_breaker do
    failure_threshold 10
    timeout 30.seconds
  end
end
```

### Service Builder Methods

#### `expose(*methods)`

Exposes specific service methods.

**Parameters:**
- `methods` (Symbol...) - Method names to expose

#### `expose_all`

Exposes all service methods.

#### `block(*methods)`

Blocks specific service methods.

**Parameters:**
- `methods` (Symbol...) - Method names to block

#### `version(value)`

Sets preferred service version.

**Parameters:**
- `value` (String) - Version string

#### `prefix(value)`

Sets URL prefix for service routes.

**Parameters:**
- `value` (String) - URL prefix

#### `timeout(value)`

Sets service call timeout.

**Parameters:**
- `value` (Time::Span) - Timeout duration

#### `require_auth(value)`

Enables/disables authentication requirement.

**Parameters:**
- `value` (Bool) - Whether auth is required

#### `require_role(role, for: methods?)`

Requires specific role for access.

**Parameters:**
- `role` (String|Symbol) - Required role
- `for` (Array(Symbol)?) - Specific methods (optional)

### Route Configuration

#### `route(method, path, to: service_method)`

Adds a custom route.

**Parameters:**
- `method` (String) - HTTP method
- `path` (String) - URL path pattern
- `to` (String) - Target service method

**Example:**
```crystal
route "GET", "/users/:id", to: "get_user"
route "POST", "/users", to: "create_user"
```

#### `rest_routes(base_path, &block)`

Configures RESTful routes.

**Parameters:**
- `base_path` (String) - Base URL path
- `&block` - REST configuration block

**Example:**
```crystal
rest_routes "/users" do
  index :list_users      # GET /users
  show :get_user        # GET /users/:id
  create :create_user   # POST /users
  update :update_user   # PUT /users/:id
  destroy :delete_user  # DELETE /users/:id
end
```

### Advanced Features

#### `circuit_breaker(&block)`

Configures circuit breaker.

**Example:**
```crystal
circuit_breaker do
  failure_threshold 5
  success_threshold 2
  timeout 30.seconds
  half_open_requests 3
end
```

#### `retry_policy(&block)`

Configures retry policy.

**Example:**
```crystal
retry_policy do
  max_attempts 3
  backoff 1.second
  backoff_multiplier 2.0
  max_backoff 30.seconds
end
```

#### `transform_response(&block)`

Adds response transformation.

**Parameters:**
- `&block` (JSON::Any -> JSON::Any) - Transformation function

**Example:**
```crystal
transform_response do |response|
  # Add metadata
  response.as_h.merge({
    "timestamp" => Time.utc.to_rfc3339,
    "version" => "1.0"
  })
end
```

#### `cache(*methods, ttl: duration)`

Enables caching for methods.

**Parameters:**
- `methods` (Symbol...) - Methods to cache
- `ttl` (Time::Span) - Cache duration

**Example:**
```crystal
cache :list, :get, ttl: 5.minutes
```

#### `aggregate(method, path, &block)`

Creates an aggregation endpoint.

**Parameters:**
- `method` (Symbol) - HTTP method
- `path` (String) - URL path
- `&block` - Aggregation logic

**Example:**
```crystal
aggregate :get, "/dashboard" do |context|
  # The handler receives HTTP::Server::Context
  # and must return JSON::Any
  
  # Fetch from multiple services (pseudo-code)
  users = fetch_users_from_service
  stats = fetch_stats_from_service
  
  # Return JSON::Any
  JSON::Any.new({
    "users" => users,
    "stats" => stats,
    "timestamp" => Time.utc.to_rfc3339
  })
end
```

### Documentation Configuration

#### `documentation(&block)`

Configures API documentation.

**Example:**
```crystal
documentation do
  title "My API"
  version "1.0.0"
  description "Production API Gateway"
  
  auto_generate_schemas [
    "User",
    "Order",
    "Product"
  ]
  
  security :bearer do
    description "JWT authentication"
  end
end
```

### Health Check Configuration

#### `health_check(&block)`

Configures custom health check.

**Parameters:**
- `&block` (-> HealthCheckResponse) - Health check handler

**Example:**
```crystal
health_check do
  services = check_backend_services
  uptime = Time.monotonic - start_time
  
  HealthCheckResponse.new(
    status: services.all?(&.last) ? :healthy : :unhealthy,
    services: services,
    uptime: uptime.total_seconds
  )
end
```

## Complete Examples

### Basic Microservice
```crystal
# Define the service
@[Micro::Service(name: "calculator")]
class CalculatorService
  include Micro::ServiceBase
  
  @[Micro::Method]
  def add(a : Float64, b : Float64) : Float64
    a + b
  end
  
  @[Micro::Method]
  def multiply(a : Float64, b : Float64) : Float64
    a * b
  end
end

# Run the service
CalculatorService.run(
  transport: Micro::Transports.http,
  registry: Micro::Registries.consul
)
```

### Client Usage
```crystal
# Create client
client = Micro.client

# Call service
result = client.call(
  "calculator",
  "add",
  {a: 10, b: 20}.to_json.to_slice
)

sum = JSON.parse(String.new(result.body))["result"]
puts "Sum: #{sum}" # Sum: 30
```

### Complete Gateway
```crystal
gateway = Micro::Gateway.build do
  name "api-gateway"
  port 8080
  
  registry :consul do
    address ENV["CONSUL_ADDR"]
  end
  
  documentation do
    title "Production API"
    version "1.0.0"
  end
  
  service "user-service" do
    prefix "/api/v1/users"
    expose_all
    
    require_auth true
    require_role :user, for: [:list, :get]
    require_role :admin, for: [:create, :update, :delete]
    
    circuit_breaker do
      failure_threshold 10
    end
    
    cache :list, :get, ttl: 1.minute
  end
  
  service "product-service" do
    prefix "/api/v1/products"
    
    rest_routes "/products" do
      index :list_products
      show :get_product
      create :create_product
      update :update_product
      destroy :delete_product
    end
    
    # Public read access
    route "GET", "/products", to: "list_products" do
      public true
    end
    
    route "GET", "/products/:id", to: "get_product" do
      public true
    end
  end
end

gateway.run
```

## Type Aliases

µCrystal provides convenient type aliases at the module level:

- `Micro::Context` - Alias for `Core::Context`
- `Micro::Request` - Alias for `Core::Request`
- `Micro::ServiceResponse` - Alias for `Core::Response`
- `Micro::ServiceOptions` - Alias for `Core::Service::Options`
- `Micro::ServerOptions` - Alias for `Core::ServerOptions`
- `Micro::CallOptions` - Alias for `Core::CallOptions`
- `Micro::TransportRequest` - Alias for `Core::TransportRequest`
- `Micro::TransportResponse` - Alias for `Core::TransportResponse`
- `Micro::Stream` - Alias for `Core::Stream`
- `Micro::Client` - Alias for `Core::Client`

These aliases allow cleaner code without the `Core::` prefix.