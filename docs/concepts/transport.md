# Transport

## Table of contents

- [Key concepts](#key-concepts)
- [Available transports](#available-transports)
- [Using transports](#using-transports)
- [Custom transports](#custom-transports)
- [Transport selection](#transport-selection)
- [Configuration examples](#configuration-examples)
- [Testing with transports](#testing-with-transports)
- [Performance considerations](#performance-considerations)
- [Related concepts](#related-concepts)

Transports handle the network communication layer between services. They abstract away the details of how requests and responses are sent over the wire, allowing services to focus on business logic.

## Key concepts

### Transport interface
All transports implement the `Micro::Core::Transport` interface, which defines methods for creating listeners and dialing connections. This allows different transport implementations to be used interchangeably.

### Listeners and connections
A listener accepts incoming connections on a specific address. Each connection can handle multiple concurrent requests using Crystal's fiber-based concurrency model.

### Request/response model
Transports use a simple request/response model. Requests include the service name, method, and encoded payload. Responses contain the result or error.

## Available transports

### HTTP transport

The default transport uses HTTP/1.1 with keep-alive connections:

```crystal
transport = Micro::Stdlib::Transports::HTTPTransport.new(
  Micro::Core::Transport::Options.new(
    timeout: 30.seconds,
    secure: false
  )
)

service_options = Micro::ServiceOptions.new(
  name: "api",
  version: "1.0.0",
  transport: transport,
  server_options: Micro::Core::ServerOptions.new(
    address: "0.0.0.0:8080"
  )
)
```

HTTP transport characteristics:
- Wide compatibility with proxies and load balancers
- Easy debugging with standard tools
- Supports middleware like compression and authentication
- Higher overhead than binary protocols

### WebSocket transport

For persistent connections and lower latency:

```crystal
transport = Micro::Transports.websocket(
  Micro::Core::Transport::Options.new(
    timeout: 30.seconds
  )
)
```

WebSocket transport characteristics:
- Persistent connections reduce handshake overhead
- Bidirectional communication
- Lower latency for frequent requests
- Requires WebSocket-aware proxies

### Loopback transport

For testing and single-process deployments:

```crystal
transport = Micro::Stdlib::Transports::LoopbackTransport.new(
  Micro::Core::Transport::Options.new
)

# Services using loopback transport communicate in-memory
# No network overhead, perfect for unit tests
```

Loopback transport characteristics:
- Zero network overhead
- Synchronous in-memory communication
- Ideal for testing service interactions
- Only works within a single process

## Using transports

### Client-side usage

Transports are typically used indirectly through the client:

```crystal
client = Micro.client(Micro::Transports.http)

# The client uses the transport to dial services
response = client.call("greeter", "say_hello", {name: "World"})
```

### Server-side usage

Services use transports to listen for incoming requests:

```crystal
@[Micro::Service(name: "api")]
class APIService
  include Micro::ServiceBase
  
  # Methods will be exposed via the configured transport
  @[Micro::Method]
  def get_data(ctx : Micro::Core::Context, req : Request) : Response
    Response.new(data: "Hello from #{options.transport.protocol}")
  end
end

# Configure transport when running the service
APIService.run(Micro::ServiceOptions.new(
  name: "api",
  version: "1.0.0",
  transport: Micro::Transports.websocket,
  server_options: Micro::Core::ServerOptions.new(
    address: "0.0.0.0:8080"
  )
))
```

## Custom transports

You can implement custom transports for specific protocols:

```crystal
class GRPCTransport < Micro::Core::Transport
  def protocol : String
    "grpc"
  end
  
  def start : Nil
    @started = true
  end
  
  def stop : Nil
    @started = false
  end
  
  def address : String
    options.address
  end
  
  def listen(address : String) : Micro::Core::Listener
    # Create a gRPC server listening on address
    # Convert gRPC requests to transport requests
    GRPCListener.new(address)
  end
  
  def dial(address : String, opts : Micro::Core::DialOptions? = nil) : Micro::Core::Socket
    # Create a gRPC client connection
    GRPCConnection.new(address, opts || Micro::Core::DialOptions.new)
  end
end
```

## Transport selection

Choose your transport based on these factors:

### Use HTTP transport when:
- You need compatibility with existing infrastructure
- Debugging and monitoring are priorities
- You're building REST-compatible services
- Firewall traversal is required

### Use WebSocket transport when:
- Low latency is critical
- You have many requests between the same services
- Bidirectional streaming is needed
- You control the infrastructure

### Use loopback transport when:
- Writing unit tests
- Building single-process applications
- Developing locally
- Maximum performance is needed (no network)

## Configuration examples

### High-throughput configuration

```crystal
transport = Micro::Stdlib::Transports::HTTPTransport.new(
  Micro::Core::Transport::Options.new(
    timeout: 5.seconds,        # Lower timeout for fast failures
    secure: false
  )
)
```

### Resilient configuration

```crystal
transport = Micro::Stdlib::Transports::HTTPTransport.new(
  Micro::Core::Transport::Options.new(
    timeout: 30.seconds,       # Higher timeout for slow operations
    secure: false
  )
)

# Configure retries at the client level
client = Micro.client(transport: transport)
```

## Testing with transports

Use the loopback transport for deterministic tests:

```crystal
describe "OrderService" do
  it "processes orders" do
    transport = Micro::Transports.loopback
    registry = Micro::Registries.memory
    
    # Start services with loopback transport
    spawn do
      OrderService.run(Micro::ServiceOptions.new(
        name: "orders",
        version: "1.0.0",
        transport: transport,
        registry: registry,
        server_options: Micro::Core::ServerOptions.new(
          address: "orders:8080"
        )
      ))
    end
    
    # Client automatically uses loopback for registered services
    client = Micro.client(transport: transport)
    response = client.call("orders", "create", {item: "Widget"})
    
    response.success?.should be_true
  end
end
```

## Performance considerations

### Connection pooling
The HTTP client can enable pooling via `Micro::Stdlib::Client#enable_pooling(address)`. WebSocket maintains per-socket connections; there is no shared pool.

### Protocol overhead
- HTTP: ~200 bytes per request for headers
- WebSocket: ~2-14 bytes per frame
- Loopback: 0 bytes (direct memory access)

Choose based on your message size and frequency.

## Related concepts

- [Services](services.md) - How services use transports
- [Registry](registry.md) - Service discovery for transport endpoints
- [Codecs](codecs.md) - Data encoding over transports
- [Context](context.md) - Metadata propagation across transports