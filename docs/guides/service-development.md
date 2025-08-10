# Service Development Guide

This guide covers the essential concepts and patterns for developing microservices with µCrystal, including using annotations, handling requests/responses, and error management.

## Table of Contents

- [Creating a Basic Service](#creating-a-basic-service)
- [Service Annotations](#service-annotations)
- [Method Annotations](#method-annotations)
- [Request and Response Handling](#request-and-response-handling)
- [Error Handling](#error-handling)
- [Service Configuration](#service-configuration)
- [Best Practices](#best-practices)

## Creating a Basic Service

Services in µCrystal are Crystal classes that include `Micro::ServiceBase` and use annotations for configuration:

```crystal
require "micro"

@[Micro::Service(name: "catalog", version: "1.0.0")]
class CatalogService
  include Micro::ServiceBase

  @[Micro::Method]
  def list_products : Array(Product)
    # Your implementation
  end
end
```

To run the service:

```crystal
options = Micro::Core::Service::Options.new(
  name: "catalog",
  version: "1.0.0",
  server_options: Micro::Core::ServerOptions.new(
    address: "0.0.0.0:8080"
  ),
  registry: Micro::Stdlib::Registries::ConsulRegistry.new
)

CatalogService.run(options)

# Or use defaults from annotations
CatalogService.run
```

## Service Annotations

### @[Micro::Service]

The `@[Micro::Service]` annotation configures service metadata:

```crystal
@[Micro::Service(
  name: "catalog",
  version: "1.0.0",
  description: "Product catalog service"
)]
```

Parameters:
- `name` (required): Service identifier used for discovery
- `version` (required): Semantic version string
- `description` (optional): Human-readable description

### @[Micro::Middleware]

Configure middleware stack for the entire service:

```crystal
@[Micro::Middleware([
  "request_id",      # Adds X-Request-ID tracking
  "logging",         # Logs requests/responses
  "timing",          # Tracks request duration
  "error_handler",   # Handles exceptions gracefully
  "cors",            # CORS support
  "compression"      # Response compression
])]
```

Middleware executes in the order specified. See the [Middleware Guide](middleware.md) for details.

## Method Annotations

### @[Micro::Method]

Expose class methods as RPC endpoints:

```crystal
@[Micro::Method]
def get_product(id : String) : Product?
  products.find { |p| p.id == id }
end
```

The method name becomes the RPC endpoint (e.g., `/get_product`).

### @[Micro::AllowAnonymous]

Bypass authentication for specific methods:

```crystal
@[Micro::Method]
@[Micro::AllowAnonymous]
def health_check : HealthStatus
  HealthStatus.new(status: "ok")
end
```

### @[Micro::RequireRole]

Enforce role-based access control:

```crystal
@[Micro::Method]
@[Micro::RequireRole("admin")]
def delete_product(id : String) : Bool
  products.delete(id)
end
```

### @[Micro::RateLimit]

Apply rate limiting to methods:

```crystal
@[Micro::Method]
@[Micro::RateLimit(requests: 100, per: 60)] # 100 requests per minute
def search_products(query : String) : Array(Product)
  # Search implementation
end
```

## Request and Response Handling

### Method Parameters

Methods can accept:
- Primitive types (`String`, `Int32`, `Float64`, `Bool`)
- Structs with `JSON::Serializable`
- Arrays and hashes of supported types

```crystal
# Single parameter (passed as JSON string or primitive)
@[Micro::Method]
def get_product(id : String) : Product?
  # ...
end

# Complex input struct
struct CreateProductInput
  include JSON::Serializable
  getter name : String
  getter price : Float64
  getter category : String?
end

@[Micro::Method]
def create_product(input : CreateProductInput) : Product
  # ...
end
```

### Response Types

Methods can return:
- Primitive types
- Structs with `JSON::Serializable`
- Arrays and hashes
- `Nil` for empty responses

```crystal
struct Product
  include JSON::Serializable
  getter id : String
  getter name : String
  getter price : Float64
end

@[Micro::Method]
def list_products : Array(Product)
  products.values
end

@[Micro::Method]
def get_product(id : String) : Product?
  products[id]?  # Returns nil if not found
end
```

### Accessing Request Context

For advanced scenarios, access the full context:

```crystal
@[Micro::Method]
def advanced_method(data : String, context : Micro::Core::Context) : Response
  # Access headers
  auth_token = context.request.headers["Authorization"]?
  
  # Get user from auth middleware
  user = context.get("user", String)
  
  # Set response headers
  context.response.headers["X-Custom"] = "value"
  
  Response.new(data: data, user: user)
end
```

## Error Handling

### Built-in Error Types

µCrystal provides standard error types:

```crystal
@[Micro::Method]
def get_product(id : String) : Product
  product = products[id]?
  
  unless product
    raise Micro::Core::NotFoundError.new("Product not found: #{id}")
  end
  
  product
end
```

Common error types:
- `Micro::Core::NotFoundError` (404)
- `Micro::Core::BadRequestError` (400)
- `Micro::Core::UnauthorizedError` (401)
- `Micro::Core::ForbiddenError` (403)
- `Micro::Core::ConflictError` (409)
- `Micro::Core::ValidationError` (422)

### Custom Error Handling

Create custom error types:

```crystal
class BusinessLogicError < Micro::Core::ServiceError
  def initialize(message : String, details : Hash(String, String)? = nil)
    super(message, code: "BUSINESS_LOGIC_ERROR", status: 422, details: details)
  end
end

@[Micro::Method]
def process_order(order : Order) : Result
  if order.items.empty?
    raise BusinessLogicError.new(
      "Order must contain items",
      {"order_id" => order.id}
    )
  end
  # Process...
end
```

### Error Response Format

Errors are automatically formatted as JSON:

```json
{
  "error": "Order must contain items",
  "code": "BUSINESS_LOGIC_ERROR",
  "details": {
    "order_id": "12345"
  }
}
```

## Service Configuration

### Running with Options

```crystal
options = Micro::Core::Service::Options.new(
  name: "catalog",
  version: "1.0.0",
  server_options: Micro::Core::ServerOptions.new(
    address: "0.0.0.0:8080",
    advertise: "catalog.internal:8080"
  ),
  registry: Micro::Stdlib::Registries::ConsulRegistry.new(
    address: ENV["CONSUL_ADDR"]
  ),
  broker: Micro::Stdlib::Brokers::NATSBroker.new(
    servers: ["nats://localhost:4222"]
  )
)

CatalogService.run(options)
```

### Environment Variables

Services respect these environment variables:

- `MICRO_SERVER_ADDRESS`: Override bind address
- `MICRO_ADVERTISE_ADDRESS`: Override advertise address
- `CONSUL_ADDR`: Consul server address
- `NATS_URL`: NATS server URL
- `LOG_LEVEL`: Logging level (debug, info, warn, error)


## Best Practices

### 1. Use Structured Types

Prefer structs over primitives for complex data:

```crystal
# Good: Clear contract
struct CreateOrderInput
  include JSON::Serializable
  getter customer_id : String
  getter items : Array(OrderItem)
  getter shipping_address : Address
end

@[Micro::Method]
def create_order(input : CreateOrderInput) : Order
  # Implementation
end

# Avoid: Ambiguous parameters
@[Micro::Method]  
def create_order(data : Hash(String, JSON::Any)) : Order
  # Requires manual validation
end
```

### 2. Validate Inputs

Validate early and return clear errors:

```crystal
@[Micro::Method]
def update_product(id : String, updates : ProductUpdate) : Product
  # Validate ID format
  unless id.matches?(/^[a-z0-9-]+$/)
    raise Micro::Core::BadRequestError.new("Invalid product ID format")
  end
  
  # Validate price
  if updates.price && updates.price.not_nil! < 0
    raise Micro::Core::ValidationError.new("Price must be positive")
  end
  
  # Update logic...
end
```

### 3. Handle Nil Values

Be explicit about optional values:

```crystal
struct Product
  include JSON::Serializable
  getter id : String
  getter name : String
  getter description : String?  # Optional
  getter tags : Array(String)?  # Optional
  
  def formatted_description : String
    description || "No description available"
  end
end
```

### 4. Use Appropriate Status Codes

Return semantically correct HTTP status codes via errors:

```crystal
@[Micro::Method]
def delete_product(id : String) : Bool
  product = products[id]?
  
  # 404 for not found
  raise Micro::Core::NotFoundError.new("Product not found") unless product
  
  # 409 for business rule violations
  if product.has_orders?
    raise Micro::Core::ConflictError.new("Cannot delete product with orders")
  end
  
  products.delete(id)
  true
end
```

### 5. Implement Idempotency

Make operations idempotent where possible:

```crystal
@[Micro::Method]
def create_product(input : CreateProductInput) : Product
  # Check if already exists
  if existing = products[input.id]?
    # Return existing instead of error for idempotency
    return existing if existing.matches?(input)
    
    # Only error if attempting to create with different data
    raise Micro::Core::ConflictError.new("Product exists with different data")
  end
  
  # Create new
  product = Product.new(input)
  products[input.id] = product
  product
end
```

### 6. Log Appropriately

Use structured logging:

```crystal
class CatalogService
  include Micro::ServiceBase
  
  Log = ::Log.for(self)
  
  @[Micro::Method]
  def create_product(input : CreateProductInput) : Product
    Log.info { "Creating product: #{input.name}" }
    
    product = Product.new(input)
    products[product.id] = product
    
    Log.info { "Created product: #{product.id}" }
    product
  rescue ex
    Log.error(exception: ex) { "Failed to create product: #{input.name}" }
    raise
  end
end
```

## Next Steps

- Learn about [Client Communication](client-communication.md) to call other services
- Explore [Middleware](middleware.md) for cross-cutting concerns
- Set up [Authentication & Security](auth-security.md)
- Configure [Monitoring](monitoring.md) for production