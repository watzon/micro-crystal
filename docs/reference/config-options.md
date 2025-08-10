# µCrystal Configuration Options Reference

## Table of contents

- [Service configuration](#service-configuration)
- [Transport configuration](#transport-configuration)
- [Registry configuration](#registry-configuration)
- [Gateway configuration](#gateway-configuration)
- [Middleware configuration](#middleware-configuration)
- [Environment variables](#environment-variables)
- [Configuration patterns](#configuration-patterns)

This document provides a complete reference for all configuration options available in µCrystal.

## Service Configuration

### ServiceOptions

Configuration options for microservices.

**Properties:**
- `name` (String) - Service name for registration
- `version` (String) - Service version (default: "latest")
- `metadata` (HTTP::Headers) - Service metadata headers
- `transport` (Core::Transport?) - Transport implementation
- `codec` (Core::Codec?) - Default codec for serialization
- `registry` (Core::Registry::Base?) - Service registry
- `broker` (Core::Broker::Base?) - Message broker
- `pubsub` (Core::PubSub::Base?) - Pub/sub implementation
- `server_options` (ServerOptions?) - Server configuration
- `auto_deregister` (Bool) - Auto-deregister on shutdown (default: true)

**Example:**
```crystal
options = Micro::ServiceOptions.new(
  name: "my-service",
  version: "1.0.0",
  metadata: HTTP::Headers{"X-Service-Type" => "api"},
  transport: Micro::Transports.http,
  codec: Micro::Codecs.json,
  registry: Micro::Registries.consul,
  auto_deregister: true
)

service = MyService.new(options)
```

**Related:** `ServerOptions`, Transport options, Registry options

### ServerOptions

Configuration for service servers.

**Properties:**
- `address` (String) - Bind address (default: "0.0.0.0:0")
- `advertise` (String?) - Advertise address for discovery
- `max_connections` (Int32) - Maximum concurrent connections (default: 1000)
- `read_timeout` (Time::Span) - Read timeout (default: 30.seconds)
- `write_timeout` (Time::Span) - Write timeout (default: 30.seconds)
- `metadata` (HTTP::Headers) - Server metadata

**Example:**
```crystal
server_options = Micro::ServerOptions.new(
  address: "0.0.0.0:8080",
  advertise: "api.example.com:8080",
  max_connections: 5000,
  read_timeout: 60.seconds,
  write_timeout: 60.seconds
)
```

**Related:** `ServiceOptions`, Transport configuration

## Transport Configuration

### Transport::Options

Base transport configuration.

**Properties:**
- `address` (String) - Transport address (default: "0.0.0.0:0")
- `timeout` (Time::Span) - Connection timeout (default: 30.seconds)
- `secure` (Bool) - Use TLS/SSL (default: false)
- `metadata` (HTTP::Headers) - Transport metadata
- `tls_config` (TLSConfig?) - TLS configuration

**Example:**
```crystal
transport_options = Micro::Core::Transport::Options.new(
  address: "0.0.0.0:8080",
  timeout: 60.seconds,
  secure: true,
  tls_config: tls_config
)
```

**Related:** `TLSConfig`, `DialOptions`

### DialOptions

Options for outgoing connections.

**Properties:**
- `timeout` (Time::Span) - Connection timeout (default: 30.seconds)
- `secure` (Bool) - Use TLS/SSL (default: false)
- `metadata` (HTTP::Headers) - Connection metadata
- `tls_config` (TLSConfig?) - TLS configuration

**Example:**
```crystal
dial_options = Micro::Core::DialOptions.new(
  timeout: 10.seconds,
  secure: true,
  metadata: HTTP::Headers{"X-Client-ID" => "client-123"}
)
```

**Related:** `CallOptions`, Transport configuration

### CallOptions

Options for RPC calls.

**Properties:**
- `timeout` (Time::Span) - Call timeout (default: 30.seconds)
- `headers` (HTTP::Headers) - Request headers
- `retry_count` (Int32) - Retry attempts (default: 0)
- `retry_delay` (Time::Span) - Delay between retries (default: 1.second)

**Example:**
```crystal
call_options = Micro::CallOptions.new(
  timeout: 10.seconds,
  headers: HTTP::Headers{"X-Request-ID" => UUID.random.to_s},
  retry_count: 3,
  retry_delay: 2.seconds
)

response = client.call("service", "method", payload, call_options)
```

**Related:** `DialOptions`, Client configuration

### TLSConfig

TLS/SSL configuration (in `Micro::Stdlib`).

**Properties:**
- `cert_file` (String?) - Certificate file path
- `key_file` (String?) - Private key file path
- `ca_file` (String?) - CA certificate file path
- `verify_mode` (OpenSSL::SSL::VerifyMode) - Certificate verification mode
- `ciphers` (String?) - Cipher suite specification

**Example:**
```crystal
tls_config = Micro::Stdlib::TLSConfig.new(
  cert_file: "/path/to/cert.pem",
  key_file: "/path/to/key.pem",
  ca_file: "/path/to/ca.pem",
  verify_mode: OpenSSL::SSL::VerifyMode::PEER
)
```

**Related:** Transport options

## Registry Configuration

### Registry::Options

Configuration for service registries.

**Properties:**
- `type` (String) - Registry type ("memory", "consul")
- `addresses` (Array(String)) - Registry addresses
- `timeout` (Time::Span) - Operation timeout (default: 10.seconds)
- `secure` (Bool) - Use secure connection (default: false)
- `metadata` (HTTP::Headers) - Registry metadata

**Example:**
```crystal
# Consul registry
registry_options = Micro::Core::Registry::Options.new(
  type: "consul",
  addresses: ["consul.service.consul:8500"],
  timeout: 5.seconds,
  secure: false
)

registry = Micro::Registries.consul(registry_options)
```

**Related:** Service discovery, Health checks

## Gateway Configuration

### Gateway::Config

Main API Gateway configuration.

**Properties:**
- `name` (String) - Gateway name (default: "api-gateway")
- `version` (String) - Gateway version (default: "1.0.0")
- `host` (String) - Bind host (default: "0.0.0.0")
- `port` (Int32) - Bind port (default: 8080)
- `registry` (Core::Registry::Base?) - Service registry
- `enable_docs` (Bool) - Enable OpenAPI docs (default: false)
- `docs_path` (String) - Documentation path (default: "/api/docs")
- `middleware` (Array(Core::Middleware)) - Global middleware
- `services` (Hash(String, ServiceConfig)) - Service configurations
- `global_headers` (HTTP::Headers) - Headers for all responses
- `enable_metrics` (Bool) - Enable metrics endpoint (default: false)
- `metrics_path` (String) - Metrics path (default: "/metrics")
- `health_path` (String) - Health check path (default: "/health")
- `request_timeout` (Time::Span) - Global timeout (default: 30.seconds)
- `enable_cors` (Bool) - Enable CORS (default: true)
- `cors_config` (CORSConfig?) - CORS configuration
- `health_handler` (Proc(HealthCheckResponse)?) - Custom health check
- `docs_title` (String) - API documentation title
- `docs_version` (String) - API documentation version
- `docs_description` (String) - API documentation description
- `schema_types` (Array(String)?) - Types to include in schemas

**Example:**
```crystal
config = Micro::Gateway::Config.new(
  name: "my-gateway",
  version: "2.0.0",
  host: "0.0.0.0",
  port: 8080,
  enable_docs: true,
  docs_path: "/api/v2/docs",
  enable_metrics: true,
  request_timeout: 60.seconds
)
```

**Related:** `ServiceConfig`, `CORSConfig`, Gateway middleware

### Gateway::ServiceConfig

Configuration for individual services in the gateway.

**Properties:**
- `version` (String?) - Service version to use
- `prefix` (String?) - URL prefix for service
- `timeout` (Time::Span) - Service timeout (default: 10.seconds)
- `retry_policy` (RetryPolicy?) - Retry configuration
- `circuit_breaker` (CircuitBreakerConfig?) - Circuit breaker config
- `exposed_methods` (Array(String)?) - Methods to expose
- `blocked_methods` (Array(String)?) - Methods to block
- `transformations` (Array(ResponseTransformation)) - Response transforms
- `middleware` (Array(Core::Middleware)) - Service-specific middleware
- `routes` (Array(RouteConfig)) - Custom routes
- `require_auth` (Bool) - Require authentication (default: true)
- `required_roles` (Array(String)) - Required roles
- `cache_config` (CacheConfig?) - Caching configuration

**Example:**
```crystal
service_config = Micro::Gateway::ServiceConfig.new(
  version: "1.0.0",
  prefix: "/api/v1/users",
  timeout: 5.seconds,
  exposed_methods: ["list", "get", "create"],
  require_auth: true,
  required_roles: ["user"]
)
```

**Related:** `RouteConfig`, `RetryPolicy`, `CircuitBreakerConfig`

### Gateway::RouteConfig

Custom route configuration.

**Properties:**
- `method` (String) - HTTP method
- `path` (String) - URL path pattern
- `service_method` (String) - Target service method
- `request_type` (String?) - Expected request type
- `response_type` (String?) - Expected response type
- `public` (Bool) - Public access (default: false)
- `cache_ttl` (Time::Span?) - Cache duration
- `transformations` (Array(ResponseTransformation)) - Transformations
- `required_roles` (Array(String)) - Required roles
- `aggregate` (Bool) - Aggregation route (default: false)
- `aggregate_handler` (Proc(HTTP::Server::Context, JSON::Any)?) - Aggregation handler

**Example:**
```crystal
route = Micro::Gateway::RouteConfig.new(
  method: "GET",
  path: "/users/:id",
  service_method: "get_user",
  public: false,
  cache_ttl: 5.minutes,
  required_roles: ["user", "admin"]
)
```

**Related:** `ServiceConfig`, Response transformations

### Gateway::RetryPolicy

Retry policy configuration.

**Properties:**
- `max_attempts` (Int32) - Maximum retry attempts (default: 3)
- `backoff` (Time::Span) - Initial backoff (default: 1.second)
- `backoff_multiplier` (Float64) - Backoff multiplier (default: 2.0)
- `max_backoff` (Time::Span) - Maximum backoff (default: 30.seconds)

**Example:**
```crystal
retry_policy = Micro::Gateway::RetryPolicy.new(
  max_attempts: 5,
  backoff: 500.milliseconds,
  backoff_multiplier: 1.5,
  max_backoff: 10.seconds
)
```

**Related:** `ServiceConfig`, Circuit breaker

### Gateway::CircuitBreakerConfig

Circuit breaker configuration.

**Properties:**
- `failure_threshold` (Int32) - Failures before opening (default: 5)
- `success_threshold` (Int32) - Successes to close (default: 2)
- `timeout` (Time::Span) - Time in open state (default: 30.seconds)
- `half_open_requests` (Int32) - Requests in half-open (default: 3)

**Example:**
```crystal
circuit_breaker = Micro::Gateway::CircuitBreakerConfig.new(
  failure_threshold: 10,
  success_threshold: 5,
  timeout: 60.seconds,
  half_open_requests: 5
)
```

**Related:** `RetryPolicy`, `ServiceConfig`

### Gateway::CacheConfig

Cache configuration for services/routes.

**Properties:**
- `ttl` (Time::Span) - Cache TTL (default: 1.minute)
- `key_prefix` (String) - Cache key prefix
- `vary_by` (Array(String)) - Vary cache by (default: ["path", "query"])

**Example:**
```crystal
cache_config = Micro::Gateway::CacheConfig.new(
  ttl: 5.minutes,
  key_prefix: "api:v1:",
  vary_by: ["path", "query", "accept-language"]
)
```

**Related:** `RouteConfig`, `ServiceConfig`

### Gateway::CORSConfig

CORS configuration.

**Properties:**
- `allowed_origins` (Array(String)) - Allowed origins (default: ["*"])
- `allowed_methods` (Array(String)) - Allowed methods
- `allowed_headers` (Array(String)) - Allowed headers (default: ["*"])
- `exposed_headers` (Array(String)) - Exposed headers
- `max_age` (Int32) - Preflight cache (default: 86400)
- `allow_credentials` (Bool) - Allow credentials (default: false)

**Default allowed methods:** GET, POST, PUT, DELETE, PATCH, OPTIONS

**Example:**
```crystal
cors_config = Micro::Gateway::CORSConfig.new(
  allowed_origins: ["https://app.example.com"],
  allowed_methods: ["GET", "POST"],
  allowed_headers: ["Content-Type", "Authorization"],
  exposed_headers: ["X-Total-Count"],
  allow_credentials: true
)
```

**Related:** Gateway configuration

## Middleware Configuration

### MiddlewareConfig

Configuration for middleware chains.

**Properties:**
- `middleware` (Array(Entry)) - Middleware entries with config
- `skip` (Array(String)) - Middleware to skip
- `require` (Array(String)) - Required middleware
- `allow_anonymous` (Bool) - Allow anonymous access

**Entry properties:**
- `name` (String) - Middleware name
- `priority` (Int32) - Execution priority (default: 0)
- `options` (Hash(String, JSON::Any)?) - Middleware options

**Example:**
```crystal
middleware_config = Micro::Core::MiddlewareConfig.new
  .add_middleware("auth", priority: 100)
  .add_middleware("rate_limit", options: {"limit" => 100})
  .skip_middleware("logging")
  .require_middleware("security")
```

**Related:** Middleware annotations, specific middleware configs

### JWT Middleware Configuration

Example configuration for JWT authentication middleware:

```crystal
jwt_middleware = JWTAuthMiddleware.new(
  secret: "your-secret-key",
  algorithm: JWT::Algorithm::HS256,
  issuer: "my-app",
  audience: ["api", "web"],
  leeway: 30, # Clock skew tolerance in seconds
  claims_extractor: ->(payload : JSON::Any) {
    {
      "roles" => payload["roles"]?.try(&.as_a.map(&.as_s)),
      "tenant_id" => payload["tenant_id"]?.try(&.as_s),
    }
  }
)
```

**Related:** Authentication, `@[Micro::AllowAnonymous]`

## Environment Variables

µCrystal supports configuration through environment variables:

### Service Configuration
- `SERVICE_NAME` - Override service name
- `SERVICE_VERSION` - Override service version
- `SERVICE_ADDRESS` - Override bind address
- `SERVICE_ADVERTISE` - Override advertise address

### Registry Configuration
- `CONSUL_ADDR` - Consul address (e.g., "127.0.0.1:8500")
- `CONSUL_TOKEN` - Consul ACL token
- `CONSUL_DATACENTER` - Consul datacenter

### Broker Configuration
- `NATS_URL` - NATS server URL
- `NATS_USER` - NATS username
- `NATS_PASSWORD` - NATS password

### Logging
- `LOG_LEVEL` - Log level (debug, info, warn, error)

## Configuration Patterns

### Development Configuration
```crystal
# Single-process development with in-memory registry
service_options = Micro::ServiceOptions.new(
  name: "dev-service",
  version: "dev",
  registry: Micro::Registries.memory,
  broker: Micro::Brokers.memory,
  transport: Micro::Transports.http(
    Micro::Core::Transport::Options.new(
      address: "localhost:8080"
    )
  )
)
```

### Production Configuration
```crystal
# Distributed production with Consul and NATS
service_options = Micro::ServiceOptions.new(
  name: ENV["SERVICE_NAME"],
  version: ENV["SERVICE_VERSION"],
  registry: Micro::Registries.consul(
    Micro::Core::Registry::Options.new(
      addresses: [ENV["CONSUL_ADDR"]],
      secure: true
    )
  ),
  broker: Micro::Brokers.nats(ENV["NATS_URL"]),
  transport: Micro::Transports.http(
    Micro::Core::Transport::Options.new(
      address: "0.0.0.0:8080",
      secure: true,
      tls_config: production_tls_config
    )
  ),
  server_options: Micro::ServerOptions.new(
    address: "0.0.0.0:8080",
    advertise: ENV["SERVICE_ADVERTISE"],
    max_connections: 10000
  )
)
```

### Gateway Configuration with DSL
```crystal
gateway = Micro::Gateway.build do
  name "api-gateway"
  version "1.0.0"
  port 8080
  
  registry :consul do
    address "consul.service.consul:8500"
  end
  
  documentation do
    title "My API"
    version "1.0.0"
    description "Production API Gateway"
  end
  
  service "user-service" do
    version "1.0.0"
    prefix "/api/v1/users"
    timeout 5.seconds
    
    expose :list, :get, :create, :update, :delete
    
    circuit_breaker do
      failure_threshold 10
      timeout 30.seconds
    end
    
    retry_policy do
      max_attempts 3
      backoff 1.second
    end
  end
end
```