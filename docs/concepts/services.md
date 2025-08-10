# Services

## Table of contents

- [Key concepts](#key-concepts)
- [Creating a service](#creating-a-service)
- [Service configuration](#service-configuration)
- [Middleware](#middleware)
- [Error handling](#error-handling)
- [Subscriptions](#subscriptions)
- [Running multiple services](#running-multiple-services)
- [Best practices](#best-practices)
- [Related concepts](#related-concepts)

Services are the fundamental building blocks in µCrystal. A service encapsulates business logic and exposes it through RPC methods that other services can discover and call.

## Key concepts

### Service definition
A service in µCrystal is a Crystal class decorated with the `@[Micro::Service]` annotation. This annotation configures the service name, version, and middleware stack at compile time.

### Methods
Methods are the RPC endpoints exposed by a service. They're defined as regular Crystal methods decorated with `@[Micro::Method]` annotations. Each method receives a context and request object, and returns a response.

### Lifecycle
Services follow a simple lifecycle: initialization, registration, listening, and shutdown. The framework handles graceful shutdown automatically, deregistering from the registry and closing connections.

## Creating a service

Here's a minimal service definition:

```crystal
require "micro"

@[Micro::Service(name: "greeter", version: "1.0.0")]
class GreeterService
  include Micro::ServiceBase

  @[Micro::Method]
  def say_hello(ctx : Micro::Core::Context, req : HelloRequest) : HelloResponse
    HelloResponse.new(message: "Hello, #{req.name}!")
  end
end

# Request and response types
struct HelloRequest
  include JSON::Serializable
  getter name : String
end

struct HelloResponse
  include JSON::Serializable
  getter message : String
end
```

## Service configuration

Services accept configuration options that control their behavior:

```crystal
options = Micro::ServiceOptions.new(
  name: "greeter",
  version: "1.0.0",
  transport: Micro::Stdlib::Transports::HTTPTransport.new(
    Micro::Core::Transport::Options.new
  ),
  codec: Micro::Stdlib::Codecs::JSON.new,
  registry: Micro::Stdlib::Registries::ConsulRegistry.new(
    Micro::Core::Registry::Options.new(type: "consul")
  ),
  server_options: Micro::Core::ServerOptions.new(
    address: "0.0.0.0:8080",
    advertise: "10.0.0.5:8080"
  )
)

GreeterService.run(options)
```

### Bind vs advertise addresses
- `server_options.address`: Where the service binds locally (e.g., "0.0.0.0:8080")
- `server_options.advertise`: What gets registered for discovery (e.g., public IP or container address)

This distinction allows services to bind to all interfaces while advertising a specific endpoint for discovery.

## Middleware

Services can configure middleware for cross-cutting concerns using annotations:

```crystal
@[Micro::Service(name: "api", version: "1.0.0")]
@[Micro::Middleware(["recovery", "request_id", "auth", "rate_limit"])]
class APIService
  include Micro::ServiceBase
  
  @[Micro::Method]
  def protected_endpoint(ctx : Micro::Core::Context, req : Request) : Response
    # Middleware runs before this method
    # Recovery, request ID, authentication, and rate limiting are already applied
    Response.new(data: "Protected data")
  end
  
  @[Micro::Method]
  @[Micro::AllowAnonymous]
  def health_check(ctx : Micro::Core::Context, req : Request) : Response
    # This endpoint bypasses auth middleware
    Response.new(data: "OK")
  end
end
```

Note: Middleware is configured via the `@[Micro::Middleware]` annotation at the class or method level, not in the `@[Micro::Service]` annotation.

## Error handling

Services should return errors using the built-in error types:

```crystal
@[Micro::Method]
def divide(ctx : Micro::Core::Context, req : DivideRequest) : DivideResponse
  if req.divisor == 0
    raise Micro::Core::Error.new(
      code: 400,
      detail: "Division by zero",
      status: "InvalidArgument"
    )
  end
  
  DivideResponse.new(result: req.dividend / req.divisor)
end
```

## Subscriptions

Services can also subscribe to pub/sub topics:

```crystal
@[Micro::Service(name: "analytics")]
class AnalyticsService
  include Micro::ServiceBase
  
  @[Micro::Subscribe(topic: "user.events")]
  def handle_user_event(ctx : Micro::Core::Context, event : UserEvent)
    # Process the event
    Log.info { "User event: #{event.type} for #{event.user_id}" }
  end
end
```

## Running multiple services

In development, you can run multiple services in a single process:

```crystal
# Use the memory registry for single-process mode
registry = Micro::Registries.memory

spawn do
  GreeterService.run(Micro::ServiceOptions.new(
    name: "greeter",
    version: "1.0.0",
    registry: registry,
    server_options: Micro::Core::ServerOptions.new(
      address: "127.0.0.1:8001"
    )
  ))
end

spawn do
  AnalyticsService.run(Micro::ServiceOptions.new(
    name: "analytics",
    version: "1.0.0",
    registry: registry,
    server_options: Micro::Core::ServerOptions.new(
      address: "127.0.0.1:8002"
    )
  ))
end

sleep
```

For production, use separate processes with a distributed registry like Consul.

## Best practices

### Keep methods focused
Each method should do one thing well. Complex operations should be broken into multiple methods or services.

### Use typed requests and responses
Always define struct types for requests and responses. This provides compile-time safety and better documentation.

### Handle context properly
The context carries request metadata and attributes. For long-running operations, check periodically for service shutdown:

```crystal
@[Micro::Method]
def long_operation(ctx : Micro::Core::Context, req : Request) : Response
  100.times do |i|
    # Check if service is shutting down
    if !running?
      raise Micro::Core::Error.new(code: 503, detail: "Service shutting down")
    end
    
    # Do work...
    sleep 0.1
  end
  
  Response.new(result: "Complete")
end
```

### Version your services
Use semantic versioning in the service annotation. This helps with backwards compatibility and gradual rollouts.

## Related concepts

- [Transport](transport.md) - How services communicate
- [Registry](registry.md) - How services discover each other
- [Context](context.md) - Request metadata and propagation
- [Codecs](codecs.md) - Data serialization formats