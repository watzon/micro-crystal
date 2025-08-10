# API Gateway Guide

This guide covers µCrystal's API Gateway, including setup, routing DSL, OpenAPI generation, and request/response transformations.

## Table of Contents

- [Gateway Overview](#gateway-overview)
- [Basic Setup](#basic-setup)
- [Routing DSL](#routing-dsl)
- [Service Proxying](#service-proxying)
- [OpenAPI Documentation](#openapi-documentation)
- [Transformations](#transformations)
- [Health Checks and Metrics](#health-checks-and-metrics)
- [Advanced Features](#advanced-features)
- [Best Practices](#best-practices)

## Gateway Overview

The API Gateway acts as a single entry point for clients, providing:

- Unified API surface for multiple backend services
- Automatic service discovery and load balancing
- Request routing and method filtering
- OpenAPI documentation generation
- Cross-cutting concerns (auth, rate limiting, CORS)
- Response transformations and aggregation
- Health monitoring and metrics

## Basic Setup

### Creating a Gateway

```crystal
require "micro/gateway"

# Basic gateway
gateway = Micro::Gateway::APIGateway.new(
  Micro::Gateway::Config.new(
    host: "0.0.0.0",
    port: 8080
  )
)

# Run the gateway
gateway.run
```

### Gateway with Service Registry

```crystal
# Configure with Consul for service discovery
config = Micro::Gateway::Config.new(
  host: "0.0.0.0",
  port: 8080,
  registry: Micro::Registries.consul(
    Micro::Core::Registry::Options.new(
      type: "consul",
      addresses: [ENV["CONSUL_ADDR"]? || "127.0.0.1:8500"]
    )
  )
)

gateway = Micro::Gateway::APIGateway.new(config)
gateway.run
```

### Full Configuration Example

```crystal
config = Micro::Gateway::Config.new(
  # Network settings
  host: "0.0.0.0",
  port: 8080,
  
  # Service discovery
  registry: consul_registry,
  
  # Features
  enable_docs: true,
  docs_path: "/api/docs",
  enable_metrics: true,
  metrics_path: "/metrics",
  
  # Health check
  health_handler: ->(Nil) {
    {status: "healthy", services: check_services}
  },
  health_path: "/health",
  
  # Middleware
  middleware: [
    "request_id",
    "logging",
    "cors",
    "compression"
  ]
)
```

## Routing DSL

### Basic routing

The gateway provides a builder DSL for defining routes:

```crystal
gateway = Micro::Gateway.build do
  name "my-api-gateway"
  version "1.0.0"
  host "0.0.0.0"
  port 8080

  # Configure services and routes
  service "catalog" do
    # HTTP method specific routes
    route "GET",    "/products",          to: "list_products"
    route "GET",    "/products/:id",      to: "get_product"
    route "POST",   "/products",          to: "create_product"
    route "PUT",    "/products/:id",      to: "update_product"
    route "DELETE", "/products/:id",      to: "delete_product"
  end

  service "orders" do
    route "GET",  "/orders",     to: "list_orders"
    route "POST", "/orders",     to: "create_order"
    route "GET",  "/orders/:id", to: "get_order"
  end
end
```

### Advanced routing

```crystal
gateway = Micro::Gateway.build do
  service "catalog" do
    # Set service-wide configuration
    prefix "/api/v1"
    timeout 30.seconds
    require_auth true

    # RESTful routes
    rest_routes "/products" do
      index  :list_products     # GET /products -> list_products
      create :create_product    # POST /products -> create_product
      show   :get_product       # GET /products/:id -> get_product
      update :update_product    # PUT /products/:id -> update_product
      destroy :delete_product   # DELETE /products/:id -> delete_product
    end

    # Custom routes
    route "GET",  "/search",                 to: "search_products"
    route "POST", "/products/:id/reviews",   to: "add_review"

    # Caching
    cache :list_products, :get_product, ttl: 5.minutes
  end
  
  service "users" do
    # Version-specific configuration
    version "2.0"
    prefix "/api/v2"
    
    # Expose only specific methods
    expose :list_users, :get_user, :create_user
    block :delete_user, :admin_functions
    
    # Role-based access
    require_role :admin, for: [:create_user, :update_user]
    
    # Define routes
    route "GET", "/users", to: "list_users"
    route "GET", "/users/:id", to: "get_user"
    route "POST", "/users", to: "create_user"
  end
end
```

### Method Filtering

Control which service methods are exposed:

```crystal
gateway = Micro::Gateway.build do
  service "admin-service" do
    prefix "/admin"
    
    # Expose all methods (be careful with this)
    expose_all
  end
  
  service "catalog" do
    prefix "/catalog"
    
    # Expose specific methods only
    expose :list_products, :get_product, :search_products
    
    # Explicitly block certain methods
    block :delete_product, :update_inventory
  end
  
  service "user-service" do
    prefix "/users"
    
    # Use expose/block to control access
    expose :get_user, :list_users, :search_users
    block :admin_delete_user, :admin_reset_password
  end
end
```

## Service Proxying

### Basic Proxying

The gateway automatically discovers and routes to services:

```crystal
# Client request: GET /catalog/products
# Gateway routes to: catalog service, list_products method

# Client request: POST /orders
# Gateway routes to: orders service, create_order method
```

### Request forwarding

The gateway forwards these elements by default:
- Request body (JSON)
- Path parameters (merged into the JSON request body)
- Select headers (excluding hop-by-hop headers)

### Load balancing

When a registry is configured, service calls from the gateway use client-side load balancing with a round-robin selector internally. There is no selector option on `Micro::Gateway::Config`.

## OpenAPI Documentation

### Automatic Generation

The gateway automatically generates OpenAPI specs from service metadata:

```crystal
# Configure OpenAPI documentation
config = Micro::Gateway::Config.new(
  enable_docs: true,
  docs_path: "/api/docs",  # Default path
  docs_title: "My API",
  docs_version: "2.0.0",
  docs_description: "Production API"
)

# Access docs at configured path (default: /api/docs)
# GET http://gateway:8080/api/docs

# Returns OpenAPI 3.0 specification
{
  "openapi": "3.0.3",
  "info": {
    "title": "My API",
    "version": "2.0.0",
    "description": "Production API"
  },
  "paths": {
    "/catalog/products": {
      "get": {
        "summary": "List all products",
        "operationId": "catalog_list_products",
        "responses": {
          "200": {
            "description": "Success",
            "content": {
              "application/json": {
                "schema": {
                  "type": "array",
                  "items": {"$ref": "#/components/schemas/Product"}
                }
              }
            }
          }
        }
      }
    }
  }
}
```

### Enhancing Documentation

Add metadata to services for better docs:

```crystal
@[Micro::Service(
  name: "catalog",
  version: "1.0.0",
  description: "Product catalog management"
)]
class CatalogService
  include Micro::ServiceBase
  
  @[Micro::Method(
    summary: "List all products",
    description: "Returns paginated list of products with optional filtering"
  )]
  @[Micro::Param(name: "category", description: "Filter by category", required: false)]
  @[Micro::Param(name: "limit", description: "Results per page", required: false, example: "20")]
  @[Micro::Param(name: "offset", description: "Pagination offset", required: false, example: "0")]
  def list_products(category : String? = nil, 
                   limit : Int32 = 20, 
                   offset : Int32 = 0) : ProductList
    # Implementation
  end
end
```

### Custom OpenAPI Extensions

```crystal
gateway = Micro::Gateway.build do
  # Configure documentation
  documentation do
    title "My API"
    version "2.0.0"
    description "Production API for ACME Corp"
    
    # Generate schemas from types
    auto_generate_schemas ["Product", "Order", "User"]
    
    # Configure security
    security :bearer_auth do
      # Security configuration is handled by middleware
    end
  end
end
```

## Transformations

### Request Transformation

Currently, request transformation happens through middleware and service method parameters. Direct request transformation blocks are not yet implemented in the DSL.

```crystal
# Use middleware for request transformation
class RequestTransformMiddleware
  include Micro::Core::Middleware
  
  def call(ctx : Micro::Core::Context, next : Micro::Core::Next) : Nil
    # Add authentication info from headers
    if user_id = ctx.request.headers["X-User-ID"]?
      ctx.set("user_id", user_id)
    end
    
    # Transform query parameters
    # Note: Query param handling is done in service methods
    
    next.call(ctx)
  end
end

# Configure gateway with middleware
config = Micro::Gateway::Config.new(
  middleware: ["request_transform"]
)
```

### Response Transformation

Modify responses before returning to clients:

```crystal
gateway = Micro::Gateway.build do
  service "catalog" do
    # Use transform_response in the service builder
    transform_response do |response|
      # The response is JSON::Any
      if product = response.as_h?
        # Add computed fields
        product["display_price"] = JSON::Any.new("$#{product["price"]?}")
        product["in_stock"] = JSON::Any.new(
          (product["inventory"]?.try(&.as_i) || 0) > 0
        )
        
        # Add HATEOAS links
        product["_links"] = JSON::Any.new({
          "self" => JSON::Any.new("/api/products/#{product["id"]?}"),
          "category" => JSON::Any.new("/api/categories/#{product["category_id"]?}"),
          "reviews" => JSON::Any.new("/api/products/#{product["id"]?}/reviews")
        })
      end
      
      JSON::Any.new(product || {} of String => JSON::Any)
    end
    
    route "GET", "/products/:id", to: "get_product"
  end
end
```

### Response Aggregation

Combine multiple service calls:

```crystal
gateway = Micro::Gateway.build do
  service "api" do
    # Define an aggregate route
    aggregate :get, "/product-details/:id" do
      parallel do
        # Fetch data from multiple services
        fetch ParallelTask.new(
          service: "catalog",
          method: "get_product",
          params: {"id" => ":id"},  # :id will be replaced with path param
          name: "product"
        )
        
        fetch ParallelTask.new(
          service: "reviews",
          method: "get_product_reviews",
          params: {"product_id" => ":id"},
          name: "reviews"
        )
        
        fetch ParallelTask.new(
          service: "inventory",
          method: "get_stock",
          params: {"product_id" => ":id"},
          name: "inventory"
        )
      end
    end
  end
end
```

## Health Checks and Metrics

### Health endpoint

Expose a health endpoint by providing a `health_handler` in the config:

```crystal
# GET /health
{
  "status": "healthy",
  "uptime_seconds": 3600,
  "services": {
    "catalog": {
      "status": "healthy",
      "instances": 3,
      "last_check": "2024-01-20T10:30:00Z"
    },
    "orders": {
      "status": "degraded",
      "instances": 1,
      "last_check": "2024-01-20T10:30:00Z",
      "error": "1 of 2 instances unhealthy"
    }
  }
}
```

### Custom Health Checks

```crystal
config = Micro::Gateway::Config.new(
  health_handler: ->(Nil) {
    # Check critical dependencies
    db_healthy = check_database_connection
    cache_healthy = check_redis_connection
    
    # Check service availability
    services = {} of String => Hash(String, JSON::Any)
    ["catalog", "orders", "users"].each do |service|
      instances = registry.list_services(service)
      services[service] = {
        "healthy" => instances.size > 0,
        "instance_count" => instances.size
      }
    end
    
    overall_health = db_healthy && cache_healthy && 
                    services.values.all? { |s| s["healthy"] }
    
    {
      status: overall_health ? "healthy" : "unhealthy",
      checks: {
        database: db_healthy,
        cache: cache_healthy,
        services: services
      }
    }
  }
)
```

### Metrics endpoint

Prometheus-compatible metrics:

```crystal
# GET /metrics
# TYPE gateway_requests_total counter
gateway_requests_total 1543

# TYPE gateway_cache_hits_total counter
gateway_cache_hits_total 42

# TYPE gateway_cache_misses_total counter
gateway_cache_misses_total 5

# TYPE gateway_response_time_seconds gauge
gateway_response_time_seconds 0.123
```

## Advanced Features

### Circuit Breaker

Protect against cascading failures:

```crystal
gateway = Micro::Gateway.build do
  service "orders" do
    # Configure circuit breaker for the service
    circuit_breaker do
      failure_threshold 5       # Failures before opening
      success_threshold 2       # Successes before closing
      timeout 30.seconds       # Time before half-open
      half_open_requests 3     # Requests in half-open state
    end
    
    route "GET", "/orders", to: "list_orders"
  end
end

# Circuit breaker is handled automatically by ServiceProxy
# When circuit opens, gateway returns 503 Service Unavailable
```

### Request Retry

Automatic retry with backoff:

```crystal
gateway = Micro::Gateway.build do
  service "critical-service" do
    # Configure retry policy for the service
    retry_policy do
      max_attempts 3
      backoff 1.second           # Base backoff duration
      backoff_multiplier 2.0     # Exponential multiplier
      max_backoff 30.seconds     # Maximum backoff time
    end
    
    route "GET", "/critical", to: "critical_operation"
  end
end
```

### Request caching

Cache responses at the gateway:

```crystal
gateway = Micro::Gateway.build do
  service "catalog" do
    # Cache specific methods
    cache :list_products, :get_product, ttl: 5.minutes
    
    route "GET", "/products", to: "list_products"
    route "GET", "/products/:id", to: "get_product"
  end
  
  service "search" do
    # Cache search results
    cache :search, ttl: 10.minutes
    
    route "GET", "/search", to: "search"
  end
end

# Note: Response storage for caching is not yet implemented. The configuration is present, but the cache write path is TODO.
```

### Rate Limiting

Rate limiting is implemented through middleware:

```crystal
# Configure rate limiting middleware
config = Micro::Gateway::Config.new(
  middleware: [
    "rate_limit"  # Add rate limiting middleware
  ]
)

# Rate limiting configuration is done through middleware options
# Per-route rate limiting requires custom middleware implementation
```

### Request Validation

Request validation is typically handled in service methods:

```crystal
# Validation happens in the service method
@[Micro::Service(name: "orders")]
class OrdersService
  include Micro::ServiceBase
  
  @[Micro::Method]
  def create_order(ctx : Micro::Core::Context, req : CreateOrderRequest) : OrderResponse
    # Validation is done by the request type
    # Invalid requests raise exceptions
    
    # Additional business rule validation
    if req.items.empty?
      raise Micro::BadRequestError.new("Order must contain at least one item")
    end
    
    # Process order...
  end
end

# Request types handle basic validation
struct CreateOrderRequest
  include JSON::Serializable
  
  getter items : Array(OrderItem)
  getter customer_id : String
  
  def initialize(@items, @customer_id)
    raise ArgumentError.new("Items cannot be empty") if @items.empty?
    raise ArgumentError.new("Customer ID required") if @customer_id.blank?
  end
end
```

### WebSocket support

WebSocket support is not implemented in the current gateway. WebSocket transport exists for service-to-service communication, but the gateway only serves HTTP.

```crystal
# Future WebSocket support will allow:
# - Proxying WebSocket connections to backend services
# - Message transformation and filtering
# - Authentication and authorization for WebSocket connections
```

## Best Practices

### 1. Use Versioning

Version your API for backward compatibility:

```crystal
gateway = Micro::Gateway.build do
  # URL versioning with prefixes
  service "catalog-v1" do
    prefix "/api/v1"
    route "GET", "/products", to: "list_products"
  end
  
  service "catalog-v2" do
    prefix "/api/v2"
    route "GET", "/products", to: "list_products"
  end
  
  # Service version preference
  service "catalog" do
    version "2.0"  # Prefer v2 instances when available
    prefix "/api"
    route "GET", "/products", to: "list_products"
  end
end
```

### 2. Implement proper error handling

The gateway handles errors automatically:

```crystal
# Gateway responses:
# - 404 Not Found - for unmatched routes
# - 503 Service Unavailable - when the circuit breaker opens
# - 401 Unauthorized - for auth failures (when you add auth)
# - 500 Internal Server Error - for unexpected errors

# Services should use standard error types:
@[Micro::Service(name: "catalog")]
class CatalogService
  include Micro::ServiceBase
  
  @[Micro::Method]
  def get_product(ctx : Micro::Core::Context, req : GetProductRequest) : Product
    product = Product.find(req.id)
    
    unless product
      # This becomes a 404 at the gateway
      raise Micro::NotFoundError.new("Product not found")
    end
    
    unless ctx.get?("user", User).try(&.can_view?(product))
      # This becomes a 403 at the gateway
      raise Micro::ForbiddenError.new("Access denied")
    end
    
    product
  end
end
```

### 3. Monitor Everything

The gateway provides built-in metrics:

```crystal
# Enable metrics endpoint
config = Micro::Gateway::Config.new(
  enable_metrics: true,
  metrics_path: "/metrics"  # Prometheus format
)

# Built-in metrics include:
# - gateway_requests_total - Total request count
# - gateway_cache_hits_total - Cache hit count
# - gateway_cache_misses_total - Cache miss count
# - gateway_response_time_seconds - Average response time

# Access metrics at: GET /metrics
# Returns Prometheus-compatible format:
# TYPE gateway_requests_total counter
# gateway_requests_total 15234
```

### 4. Implement Security Best Practices

```crystal
# Use middleware for security
config = Micro::Gateway::Config.new(
  middleware: [
    "cors",        # CORS handling
    "auth",        # Authentication
    "rate_limit",  # Rate limiting
    "compression"  # Response compression
  ]
)

# Configure CORS
config.enable_cors = true
config.cors_config = CORSConfig.new(
  allowed_origins: ["https://app.example.com"],
  allowed_methods: ["GET", "POST", "PUT", "DELETE"],
  allowed_headers: ["Authorization", "Content-Type"],
  max_age: 86400
)

# Services handle authorization
gateway = Micro::Gateway.build do
  service "admin" do
    require_auth true  # All routes require authentication
    
    route "GET", "/users", to: "list_users"
    route "DELETE", "/users/:id", to: "delete_user"
  end
  
  service "public" do
    # No auth required by default
    route "GET", "/status", to: "health_check"
  end
end
```

### 5. Document Everything

Ensure comprehensive service documentation:

```crystal
# Add metadata to services for better docs
@[Micro::Service(
  name: "catalog",
  version: "1.0.0",
  description: "Product catalog management"
)]
class CatalogService
  include Micro::ServiceBase
  
  @[Micro::Method(
    summary: "List all products",
    description: "Returns paginated list of products with optional filtering"
  )]
  @[Micro::Param(name: "category", description: "Filter by category", required: false)]
  @[Micro::Param(name: "limit", description: "Results per page", required: false, example: "20")]
  def list_products(ctx : Micro::Core::Context, req : ListProductsRequest) : ProductList
    # Implementation
  end
end

# Gateway configuration for documentation
gateway = Micro::Gateway.build do
  documentation do
    title "ACME API"
    version "2.0.0"
    description "Production API for ACME Corp"
    
    # Auto-generate schemas from Crystal types
    auto_generate_schemas [
      "Product",
      "Order",
      "User",
      "Error"
    ]
  end
end

# Access comprehensive docs at /api/docs
```

## Next Steps

- Set up [Authentication & Security](auth-security.md) for the gateway
- Configure [Monitoring](monitoring.md) and alerting
- Learn about [Testing](testing.md) gateway configurations
- Explore [Service Development](service-development.md) for backend services