# µCrystal documentation

Welcome to the documentation for µCrystal. You'll find guides, conceptual overviews, and API references organized by topic. If you're new, start with the getting started section below. Otherwise, jump to concepts, guides, or reference.

## Sections

- Concepts: [./concepts/](./concepts/)
- Guides: [./guides/](./guides/)
- Reference: [./reference/](./reference/)
- Examples: [./examples/](./examples/)
- Deployment: [./deployment/](./deployment/)

## Getting started

## Table of contents

- [Installation](#installation)
- [Creating your first service](#creating-your-first-service)
- [Understanding the basics](#understanding-the-basics)
- [Making client calls](#making-client-calls)
- [Service discovery](#service-discovery)
- [Running the hello world example](#running-the-hello-world-example)
- [Configuring your service](#configuring-your-service)
- [What's next?](#whats-next)
- [Common patterns](#common-patterns)
- [Troubleshooting](#troubleshooting)

µCrystal makes it easy to build microservices in Crystal. This guide will walk you through creating your first service, making RPC calls, and understanding service discovery basics.

## Installation

Add µCrystal to your `shard.yml`:

```yaml
dependencies:
  micro:
    github: watzon/micro-crystal
```

Then install dependencies:

```bash
shards install
```

## Creating your first service

The simplest way to create a service is using the `@[Micro::Service]` annotation:

```crystal
require "micro"

@[Micro::Service(name: "hello-service", version: "1.0.0")]
class HelloService
  include Micro::ServiceBase

  @[Micro::Method(description: "Say hello")]
  def hello(name : String) : String
    "Hello, #{name}!"
  end
end

# Start the service (binds to 0.0.0.0:8080 by default)
HelloService.run
```

That's it! Your service is now running and ready to accept RPC calls.

## Understanding the basics

When you create a service with µCrystal:

1. The `@[Micro::Service]` annotation marks your class as a service with a name and version
2. Including `Micro::ServiceBase` provides all the necessary functionality
3. The `@[Micro::Method]` annotation exposes methods as RPC endpoints
4. Calling `run` starts the service with default settings

By default, services:
- Bind to `0.0.0.0:8080` (configurable via `MICRO_SERVER_ADDRESS` environment variable)
- Use HTTP transport for communication
- Use JSON for message encoding
- Register with an in-memory registry for local development

## Making client calls

To call your service from another Crystal application:

```crystal
require "micro"

# Create a client
client = Micro.client

# Call the service method
response = client.call("hello-service", "hello", %({"name": "World"}).to_slice)

# Check response status
if response.status < 400
  puts String.new(response.body)  # {"result": "Hello, World!"}
else
  puts "Error: #{response.error}"
end
```

The client automatically discovers services using the registry and handles request/response encoding.

## Service discovery

µCrystal uses a pluggable registry system for service discovery. By default, it uses an in-memory registry perfect for development and single-process applications.

### Memory registry (default)

The memory registry keeps all service registrations in memory. It's automatically used when you run services locally:

```crystal
# Services automatically register themselves
HelloService.run  # Registered as "hello-service" in memory registry

# Clients automatically discover services
client = Micro.client
response = client.call("hello-service", "hello", payload)
```

### Switching to Consul

For distributed deployments, you can use Consul for service discovery:

```bash
# Set environment variables
export MICRO_REGISTRY=consul
export CONSUL_ADDR=localhost:8500

# Now run your service - it will register with Consul
crystal run hello_service.cr
```

## Running the hello world example

The repository includes a complete hello world example you can run:

```bash
# From the project root
crystal run examples/hello_world.cr
```

In another terminal, test it with curl:

```bash
# Call the hello method
curl -X POST http://localhost:8080/hello \
  -H "Content-Type: application/json" \
  -d '{"name": "Crystal"}'
```

## Configuring your service

Services can be configured through options:

```crystal
@[Micro::Service(name: "my-service", version: "2.0.0")]
class MyService
  include Micro::ServiceBase

  @[Micro::Method]
  def process(data : String) : String
    "Processed: #{data}"
  end
end

# Run with custom options
options = Micro::ServiceOptions.new(
  name: "my-service",
  version: "2.0.0",
  server_options: Micro::ServerOptions.new(
    address: "0.0.0.0:9090"  # Custom port
    # advertise_address will be set automatically to match address unless specified
  )
)

MyService.run(options)
```

## What's next?

Now that you have a basic service running:

- Explore [service communication patterns](./patterns/README.md) for pub/sub and streaming
- Learn about [middleware](./middleware/README.md) for authentication, rate limiting, and more
- Set up [distributed services](./deployment/README.md) with Consul
- Build an [API gateway](./gateway/README.md) to expose services to the web

## Common patterns

### Environment-based configuration

Configure services using environment variables:

```bash
# Server binding
export MICRO_SERVER_ADDRESS=0.0.0.0:9090

# Service discovery  
export MICRO_REGISTRY=consul
export CONSUL_ADDRESS=consul.example.com:8500

# Advertise address (for containers/cloud)
export MICRO_ADVERTISE_ADDRESS=10.0.0.5:9090
```

### Error handling

Services automatically handle errors and return appropriate responses:

```crystal
@[Micro::Service(name: "safe-service")]
class SafeService
  include Micro::ServiceBase

  @[Micro::Method]
  def divide(a : Float64, b : Float64) : Float64
    raise "Division by zero" if b == 0
    a / b
  end
end
```

Errors are automatically caught and returned as error responses to clients.

### Using different codecs

While JSON is the default, you can use MessagePack for better performance:

```crystal
options = Micro::ServiceOptions.new(
  name: "fast-service",
  version: "1.0.0",  # version is required
  codec: Micro::Codecs.msgpack
)

FastService.run(options)
```

## Troubleshooting

### Service won't start

Check if the port is already in use:
```bash
lsof -i :8080
```

### Client can't find service  

Ensure both client and service use the same registry:
- For local development: both should use the default memory registry
- For distributed: both need `MICRO_REGISTRY=consul` and same `CONSUL_ADDRESS`

### Connection refused errors

- Verify the service is running: `ps aux | grep crystal`
- Check firewall rules allow connections on the service port
- For Docker/Kubernetes, set `advertise` in server_options to the externally accessible address