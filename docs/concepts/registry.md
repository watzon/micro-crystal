# Registry

## Table of contents

- [Key concepts](#key-concepts)
- [Available registries](#available-registries)
- [Service metadata](#service-metadata)
- [Health checking](#health-checking)
- [Service versioning](#service-versioning)
- [Load balancing](#load-balancing)
- [Registry patterns](#registry-patterns)
- [Watching for changes](#watching-for-changes)
- [Best practices](#best-practices)
- [Related concepts](#related-concepts)

The registry provides service discovery, allowing services to find and communicate with each other dynamically. It maintains a real-time view of available services, their endpoints, and health status.

## Key concepts

### Service registration
When a service starts, it registers itself with metadata including name, version, address, and endpoints. The registry maintains this information and makes it available for discovery.

### Service discovery
Clients query the registry to find service instances. The registry returns healthy instances that match the requested service name and version.

### Health checking
Registries monitor service health through periodic health checks or TTL-based expiration. Unhealthy services are automatically removed from discovery results.

## Available registries

### Memory registry

For single-process and development use:

```crystal
registry = Micro::Registries.memory

# All services in the same process share this registry
service_options = Micro::ServiceOptions.new(
  name: "api",
  version: "1.0.0",
  registry: registry,
  server_options: Micro::Core::ServerOptions.new(
    address: "localhost:8080"
  )
)
```

Memory registry characteristics:
- Zero network overhead
- Instant updates
- No external dependencies
- Limited to single process

### Consul registry

For distributed production deployments:

```crystal
registry = Micro::Registries.consul(
  Micro::Core::Registry::Options.new(
    type: "consul",
    addresses: [ENV["CONSUL_ADDR"]? || "127.0.0.1:8500"],
    timeout: 30.seconds,
    secure: false
  )
)

service_options = Micro::ServiceOptions.new(
  name: "api",
  version: "1.0.0",
  registry: registry,
  server_options: Micro::Core::ServerOptions.new(
    address: "0.0.0.0:8080",
    advertise: "10.0.0.5:8080"  # Public IP for discovery
  )
)
```

Consul registry characteristics:
- Distributed consensus
- Multi-datacenter support
- Built-in health checking
- DNS and HTTP interfaces

## Service metadata

Services register with rich metadata:

```crystal
@[Micro::Service(
  name: "api",
  version: "2.0.0",
  metadata: {"environment" => "production", "region" => "us-east-1", "capabilities" => "streaming,batch"}
)]
class APIService
  include Micro::ServiceBase
end
```

Service metadata is included in registration:

```crystal
# The service automatically registers with its metadata
# Metadata is available in the registry for filtering and routing decisions
service = registry.get_service("api", "2.0.0").first
puts service.metadata["region"] # => "us-east-1"
```

## Health checking

### TTL-based health

Services can register with a TTL and the registry will handle periodic updates:

```crystal
# Register with TTL
service = Micro::Core::Registry::Service.new(
  name: "api",
  version: "1.0.0",
  nodes: [
    Micro::Core::Registry::Node.new(
      id: "api-1",
      address: "10.0.0.5",
      port: 8080
    )
  ]
)

registry.register(service, ttl: 30.seconds)
```

### HTTP health checks

Consul can probe service health endpoints:

```crystal
@[Micro::Service(name: "api")]
class APIService
  include Micro::ServiceBase
  
  @[Micro::Method]
  def health(ctx : Micro::Core::Context, req : HealthRequest) : HealthResponse
    # Check database, dependencies, etc.
    if database_healthy?
      HealthResponse.new(status: "healthy")
    else
      raise Micro::Core::Error.new(code: 503, detail: "Database unavailable")
    end
  end
end

# Consul is configured externally to check service health endpoints
# Services expose health endpoints for monitoring
```

## Service versioning

The registry supports multiple versions of the same service:

```crystal
# Version 1.0 - old API
@[Micro::Service(name: "users", version: "1.0.0")]
class UsersV1Service
  include Micro::ServiceBase
  
  @[Micro::Method]
  def get_user(ctx : Micro::Core::Context, req : GetUserRequest) : UserV1
    UserV1.new(id: req.id, name: "Alice")
  end
end

# Version 2.0 - new API with more fields
@[Micro::Service(name: "users", version: "2.0.0")]
class UsersV2Service
  include Micro::ServiceBase
  
  @[Micro::Method]
  def get_user(ctx : Micro::Core::Context, req : GetUserRequest) : UserV2
    UserV2.new(id: req.id, name: "Alice", email: "alice@example.com")
  end
end

# Services automatically register with their version when started via `ServiceBase`
# Discovery-aware clients (e.g., `DiscoveryClient`) select appropriate nodes and versions
```

## Load balancing

The registry works with selectors to distribute load:

```crystal
# The registry returns all healthy service nodes
# Client-side load balancing selects which node to use

services = registry.get_service("api", "1.0.0")
# Returns array of Service objects with nodes

# Each service has multiple nodes
service = services.first
service.nodes.each do |node|
  puts "#{node.address}:#{node.port}"
end
```

## Registry patterns

### Development setup

Use memory registry for rapid development:

```crystal
# dev.cr - run all services in one process
registry = Micro::Registries.memory

options = ->(name : String, port : Int32) {
  Micro::ServiceOptions.new(
    name: name,
    version: "1.0.0",
    registry: registry,
    server_options: Micro::Core::ServerOptions.new(
      address: "127.0.0.1:#{port}"
    )
  )
}

spawn { UserService.run(options.call("users", 8001)) }
spawn { OrderService.run(options.call("orders", 8002)) }
spawn { NotificationService.run(options.call("notifications", 8003)) }

sleep
```

### Production setup

Use Consul for distributed services:

```crystal
# Each service runs in its own container/process
registry = Micro::Registries.consul(
  Micro::Core::Registry::Options.new(
    addresses: [ENV["CONSUL_ADDR"]],
    timeout: 30.seconds
  )
)

# Service automatically registers on startup
UserService.run(Micro::ServiceOptions.new(
  name: "users",
  version: "1.0.0",
  registry: registry,
  server_options: Micro::Core::ServerOptions.new(
    address: "0.0.0.0:8080",
    advertise: ENV["SERVICE_ADDR"]  # Container IP
  )
))
```

### Hybrid setup

Use multiple registries for migration:

```crystal
class MultiRegistry < Micro::Core::Registry::Base
  def initialize(@registries : Array(Micro::Core::Registry::Base))
  end
  
  def register(service : Micro::Core::Registry::Service, ttl : Time::Span? = nil) : Nil
    @registries.each { |r| r.register(service, ttl) }
  end
  
  def deregister(service : Micro::Core::Registry::Service) : Nil
    @registries.each(&.deregister(service))
  end
  
  def get_service(name : String, version : String = "*") : Array(Micro::Core::Registry::Service)
    # Try each registry and combine results
    @registries.flat_map { |r| r.get_service(name, version) }
  end
  
  def list_services : Array(Micro::Core::Registry::Service)
    @registries.flat_map(&.list_services).uniq(&.name)
  end
  
  def watch(service : String? = nil) : Micro::Core::Registry::Watcher
    # Watch first registry only for simplicity
    @registries.first.watch(service)
  end
end

# Register in both during migration
registry = MultiRegistry.new([
  Micro::Registries.memory,
  Micro::Registries.consul
])
```

## Watching for changes

Monitor service changes in real-time:

```crystal
watcher = registry.watch("api")

spawn do
  while event = watcher.next
    case event.type
    when Micro::Core::Registry::EventType::Create
      puts "New service registered: #{event.service.name}"
    when Micro::Core::Registry::EventType::Update
      puts "Service updated: #{event.service.name}"
    when Micro::Core::Registry::EventType::Delete
      puts "Service removed: #{event.service.name}"
    end
    
    # Update load balancer, caches, etc.
    update_nginx_config(event.service)
  end
end

# Stop watching when done
watcher.stop
```

## Best practices

### Use appropriate TTLs
- Development: 5-10 seconds for quick updates
- Production: 30-60 seconds to reduce registry load
- Critical services: Shorter TTLs with active health checks

### Set advertise addresses correctly
Always set advertise address in containerized environments:

```crystal
service_options = Micro::ServiceOptions.new(
  name: "api",
  version: "1.0.0",
  server_options: Micro::Core::ServerOptions.new(
    address: "0.0.0.0:8080",        # Bind to all interfaces
    advertise: container_ip()        # Register container IP
  )
)
```

### Handle registry failures
Implement fallbacks for registry unavailability:

```crystal
begin
  services = registry.get_service("api")
rescue ex : Micro::Core::Registry::RegistryError
  # Fall back to cached endpoints
  services = cached_endpoints["api"]
  Log.warn { "Registry unavailable, using cache: #{ex.message}" }
end
```

### Version services properly
Use semantic versioning to manage compatibility:
- Major: Breaking changes
- Minor: New features, backwards compatible
- Patch: Bug fixes

## Related concepts

- [Services](services.md) - How services register themselves
- [Transport](transport.md) - Network addresses in registry
- [Context](context.md) - Service metadata propagation
- [Broker](broker.md) - Event-driven service discovery