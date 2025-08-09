# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

µCrystal (micro-crystal) is a batteries-included microservice toolkit for Crystal, inspired by Go-Micro. It provides composable, pluggable components for building microservices with service discovery, RPC, pub/sub messaging, and API gateway capabilities.

## Key commands

### Building and dependencies
```bash
# Install dependencies
shards install

# Check dependency status
shards check

# Update dependencies
shards update
```

### Testing
```bash
# Run all tests
crystal spec

# Run specific test file
crystal spec spec/micro/core/service_spec.cr

# Run tests with error trace
crystal spec --error-trace
```

### Linting and formatting
```bash
# Format code
crystal tool format

# Run ameba linter
./bin/ameba

# Run ameba with auto-fix
./bin/ameba --fix
```

### Demo application
```bash
# Build all demo targets
cd examples/demo
shards build dev gateway catalog orders

# Run single-process dev runner (recommended for development)
bin/dev

# Run services separately (requires Consul)
export CONSUL_ADDR=127.0.0.1:8500
bin/catalog
bin/orders  
bin/gateway
```

## Architecture and code structure

### Core namespaces
- `Micro::Core` - Core interfaces (transport, codec, registry, broker, service)
- `Micro::Stdlib` - Default implementations (HTTP transport, JSON/MsgPack codecs, memory/Consul registries)
- `Micro::Gateway` - API gateway with routing DSL, OpenAPI generation, health/metrics
- `Micro::Macros` - Compile-time code generation for services, methods, subscriptions

### Service definition pattern
Services use annotation-based macros for compile-time configuration:
- `@[Micro::Service]` - declare service with name, version, middleware
- `@[Micro::Method]` - expose method as RPC endpoint
- `@[Micro::Subscribe]` - subscribe to broker topics

### Pluggable components
All components are pluggable via interfaces in `Micro::Core`:
- Transports: HTTP, WebSocket (HTTP2 planned)
- Codecs: JSON, MsgPack  
- Registries: Memory (single-process), Consul (distributed)
- Brokers: Memory, NATS
- Selectors: Round-robin, random

### Registry addressing
Services distinguish between bind and advertise addresses:
- `address`: Where service binds (e.g., "0.0.0.0:8080")
- `advertise_address`: What gets registered for discovery (e.g., container IP, public endpoint)

### Middleware pipeline
Opinionated middleware stack for cross-cutting concerns:
- Authentication (JWT, mTLS)
- Authorization (RBAC)
- Rate limiting
- Circuit breakers
- Compression
- Logging/timing
- Request ID propagation

### Gateway capabilities
The API gateway provides:
- Routing DSL with Radix tree
- Method filtering (expose/block specific RPC methods)
- OpenAPI generation at `/api/docs`
- Health checks at `/health`
- Prometheus metrics at `/metrics`
- Response transformations
- Request aggregation
- CORS handling

## Crystal-specific patterns

### Avoid symbols in regular code
Use enums instead of symbols for type safety. Symbols are acceptable in macros (like Lucky framework uses them).

### No .to_sym method
Crystal doesn't have `.to_sym`. Use enums or string constants instead.

### Fiber-based concurrency
Leverages Crystal's built-in fibers and event loop for async operations without external reactors.

### Compile-time safety
Heavy use of macros and generics to generate type-safe stubs/clients and catch errors at compile time.

## Testing patterns

Tests use Crystal's built-in spec framework with:
- `describe` blocks for grouping
- `it` blocks for individual tests  
- `should` matchers for assertions
- WebMock for HTTP mocking

## Common development workflows

### Adding a new service
1. Create service class with `@[Micro::Service]` annotation
2. Add methods with `@[Micro::Method]` annotations
3. Include `Micro::ServiceBase`
4. Configure registry and transport options
5. Call `YourService.run(options)`

### Adding middleware
1. Implement `Micro::Core::Middleware` interface
2. Register in service options or globally
3. Middleware executes in registration order

### Service discovery
- Memory registry for single-process development
- Consul registry for distributed deployments
- Set `CONSUL_ADDR` environment variable to switch

### Inter-service communication
Services discover and call each other via the registry:
```crystal
client = Micro.client
response = client.call("service-name", "method", payload)
```