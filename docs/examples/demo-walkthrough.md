# Demo walkthrough

## Table of contents

- [Architecture overview](#architecture-overview)
- [Catalog service breakdown](#catalog-service-breakdown)
- [Orders service breakdown](#orders-service-breakdown)
- [Gateway configuration](#gateway-configuration)
- [Development workflow](#development-workflow)
- [Production considerations](#production-considerations)

This guide explores the demo application included with µCrystal, showing how the framework's features work together in a realistic e-commerce scenario.

## Architecture overview

The demo implements a simplified e-commerce system with three main components:

```
┌─────────────┐     ┌─────────────────┐     ┌─────────────┐
│   Gateway   │────▶│ Catalog Service │     │   Orders    │
│  (Public)   │     └─────────────────┘     │  Service    │
│             │                              │             │
│ :8080       │────────────────────────────▶│ :8082       │
└─────────────┘                              └──────┬──────┘
                                                    │
                                                    ▼
                                            ┌─────────────┐
                                            │   Catalog   │
                                            │  Service    │
                                            │ :8081       │
                                            └─────────────┘
```

**Service responsibilities:**

- **Gateway**: Public API endpoint, request routing, OpenAPI documentation
- **Catalog Service**: Product management, inventory queries
- **Orders Service**: Order creation, inter-service communication to validate products

The architecture demonstrates several µCrystal patterns:
- Service discovery via registry (Memory or Consul)
- Inter-service RPC communication
- API gateway pattern with automatic routing
- Middleware composition
- Health checks and metrics

## Catalog service breakdown

The catalog service is the simpler of the two services, managing product information:

```crystal
@[Micro::Service(name: "catalog", version: "1.0.0")]
@[Micro::Middleware([
  "request_id", "logging", "timing", "error_handler", "cors", "compression",
])]
class CatalogService
  include Micro::ServiceBase

  struct Product
    include JSON::Serializable
    getter id : String
    getter name : String
    getter price : Float64
  end

  @@products : Hash(String, Product) = begin
    seed = {} of String => Product
    seed_json = {"id" => "p-1", "name" => "Sample Product", "price" => 9.99}.to_json
    seed["p-1"] = Product.from_json(seed_json)
    seed
  end

  @[Micro::Method]
  @[Micro::AllowAnonymous]
  def list_products : Array(Product)
    @@products.values
  end

  @[Micro::Method]
  @[Micro::AllowAnonymous]
  def get_product(id : String) : Product?
    @@products[id]?
  end
end
```

**Key features demonstrated:**

1. **Simple data model**: The `Product` struct uses `JSON::Serializable` for automatic marshaling. The framework handles all serialization transparently.

2. **In-memory storage**: For demo simplicity, products are stored in a class variable. In production, this would be a database.

3. **Method exposure**: The `@[Micro::Method]` annotation exposes methods as RPC endpoints. The framework generates `/list_products` and `/get_product` endpoints automatically.

4. **Anonymous access**: The `@[Micro::AllowAnonymous]` annotation bypasses authentication middleware, making these endpoints publicly accessible.

5. **Middleware stack**: The service uses standard middleware for production-ready features:
   - `request_id`: Distributed tracing support
   - `logging`: Structured request/response logging
   - `timing`: Performance metrics
   - `error_handler`: Consistent error responses
   - `cors`: Cross-origin resource sharing
   - `compression`: Response compression

## Orders service breakdown

The orders service is more complex, demonstrating inter-service communication:

```crystal
@[Micro::Service(name: "orders", version: "1.0.0")]
@[Micro::Middleware(["request_id", "logging", "timing", "error_handler"])]
class OrderService
  include Micro::ServiceBase

  # Local view of catalog product for deserialization
  struct CatalogProduct
    include JSON::Serializable
    getter id : String
    getter name : String
    getter price : Float64
  end

  struct OrderItem
    include JSON::Serializable
    getter product_id : String
    getter quantity : Int32
  end

  struct CreateOrder
    include JSON::Serializable
    getter items : Array(OrderItem)
  end

  struct Order
    include JSON::Serializable
    getter id : String
    getter total : Float64
    getter items : Array(OrderItem)
    getter created_at : Time

    def initialize(@id : String, @total : Float64, @items : Array(OrderItem), @created_at : Time)
    end
  end

  @@orders : Hash(String, Order) = {} of String => Order

  @[Micro::Method]
  def create_order(input : CreateOrder) : Order
    total = input.items.sum do |item|
      product = fetch_catalog_product(item.product_id) || raise ArgumentError.new("Unknown product: #{item.product_id}")
      product.price * item.quantity
    end

    order = Order.new(
      id: UUID.random.to_s,
      total: total,
      items: input.items,
      created_at: Time.utc
    )
    @@orders[order.id] = order
    order
  end

  @[Micro::Method]
  def get_order(id : String) : Order?
    @@orders[id]?
  end

  private def fetch_catalog_product(product_id : String)
    response = client.call(
      service: "catalog",
      method: "/get_product",
      body: %("#{product_id}").to_slice
    )
    return nil if response.status >= 400
    json = String.new(response.body)
    return nil if json == "null"
    CatalogProduct.from_json(json)
  end
end
```

**Advanced patterns shown:**

1. **Service communication**: The `client.call` method demonstrates service-to-service RPC. The client automatically:
   - Discovers the catalog service via the registry
   - Load balances across multiple instances
   - Handles serialization/deserialization
   - Propagates request context (including request IDs)

2. **Data model separation**: The `CatalogProduct` struct is a local representation of the catalog service's product. This decoupling allows services to evolve independently.

3. **Error handling**: The service validates that products exist before creating orders, demonstrating defensive programming in distributed systems.

4. **Business logic**: Order totals are calculated by fetching current prices from the catalog service, ensuring price consistency.

## Gateway configuration

The gateway provides a unified API surface for clients:

```crystal
module DemoApp
  def self.build_gateway : Micro::Gateway::APIGateway
    registry = DemoConfig.registry

    gateway_builder = Micro::Gateway::Builder.new
    gateway_builder.name("demo-gateway")
    gateway_builder.version("1.0.0")
    gateway_builder.host(ENV["GATEWAY_HOST"]? || "0.0.0.0")
    gateway_builder.port((ENV["GATEWAY_PORT"]? || "8080").to_i)
    gateway_builder.registry(registry)
    
    # Enable OpenAPI docs and metrics
    gateway_builder.config.enable_docs = true
    gateway_builder.config.docs_path = "/api/docs"
    gateway_builder.config.enable_metrics = true
    gateway_builder.config.metrics_path = "/metrics"
    
    # Health check handler
    gateway_builder.health_check do
      services = gateway_builder.config.services.keys.map { |n| {n, true} }.to_h
      Micro::Gateway::HealthCheckResponse.new(
        status: :ok,
        services: services,
        uptime: (Time.utc - gateway_builder.build.started_at).total_seconds
      )
    end

    gateway_builder.service("catalog") do
      version("1.0.0")
      prefix("/api/catalog")
      rest_routes("/products") do
        index(:list_products)
        show(:get_product)
      end
    end

    gateway_builder.service("orders") do
      version("1.0.0")
      prefix("/api/orders")
      route("POST", "/api/orders", to: "create_order")
      rest_routes("/orders") do
        show(:get_order)
      end
    end

    gateway_builder.build
  end
end
```

**Gateway features:**

1. **Service routing**: The gateway maps public HTTP paths to internal service methods:
   - `GET /api/catalog/products` → `catalog.list_products`
   - `GET /api/catalog/products/:id` → `catalog.get_product`
   - `POST /api/orders` → `orders.create_order`
   - `GET /api/orders/:id` → `orders.get_order`

2. **REST conventions**: The `rest_routes` helper generates RESTful routes following conventions:
   - `index` → `GET /resources`
   - `show` → `GET /resources/:id`
   - `create` → `POST /resources`
   - `update` → `PUT /resources/:id`
   - `destroy` → `DELETE /resources/:id`

3. **OpenAPI generation**: The gateway automatically generates OpenAPI documentation at `/api/docs`, inferring schemas from service method signatures.

4. **Health monitoring**: The `/health` endpoint aggregates health status from all configured services.

5. **Metrics collection**: Prometheus-compatible metrics are exposed at `/metrics`, tracking request rates, latencies, and error rates.

## Development workflow

The demo includes a convenient development runner that manages all services in a single process:

### Single-process mode (recommended for development)

```bash
cd examples/demo
shards build dev
bin/dev
```

This starts all services with:
- Automatic code reloading
- Colored console output
- In-memory service registry
- Services on different ports (gateway: 8080, catalog: 8081, orders: 8082)

Output example:
```
=== µCrystal Demo - Single Process Mode ===
Using in-memory registry (single process mode)

Starting services...
[gateway] Starting on 0.0.0.0:8080
[catalog] Starting on 0.0.0.0:8081
[orders] Starting on 0.0.0.0:8082

Services registered:
✓ demo-gateway @ 127.0.0.1:8080
✓ catalog @ 127.0.0.1:8081
✓ orders @ 127.0.0.1:8082

Gateway routes:
  GET    /api/catalog/products     → catalog.list_products
  GET    /api/catalog/products/:id → catalog.get_product
  POST   /api/orders               → orders.create_order
  GET    /api/orders/:id           → orders.get_order

Special endpoints:
  GET    /health                   → Health status
  GET    /api/docs                 → OpenAPI documentation
  GET    /metrics                  → Prometheus metrics

Ready! Press Ctrl+C to stop all services.
```

### Distributed mode (production-like)

For testing distributed deployments with Consul:

```bash
# Start Consul
consul agent -dev

# In separate terminals:
export CONSUL_ADDR=127.0.0.1:8500

./bin/catalog
./bin/orders
./bin/gateway
```

Each service:
- Registers itself with Consul
- Discovers other services via Consul
- Can be scaled by running multiple instances
- Handles graceful shutdown with deregistration

### Testing the demo

Once running, test the services:

```bash
# List products
curl http://localhost:8080/api/catalog/products

# Get specific product
curl http://localhost:8080/api/catalog/products/p-1

# Create an order
curl -X POST http://localhost:8080/api/orders \
  -H "Content-Type: application/json" \
  -d '{
    "items": [
      {"product_id": "p-1", "quantity": 2}
    ]
  }'

# View OpenAPI docs
open http://localhost:8080/api/docs

# Check health
curl http://localhost:8080/health

# View metrics
curl http://localhost:8080/metrics
```

### Observing inter-service communication

The demo's logging shows service interactions:

```
[request_id: 123] [gateway] Received POST /api/orders
[request_id: 123] [gateway] Routing to orders.create_order
[request_id: 123] [orders] Processing create_order
[request_id: 123] [orders] Calling catalog.get_product for p-1
[request_id: 123] [catalog] Processing get_product: p-1
[request_id: 123] [catalog] Completed in 0.5ms
[request_id: 123] [orders] Order created: order-456
[request_id: 123] [orders] Completed in 15.2ms
[request_id: 123] [gateway] Completed in 16.8ms
```

Key observations:
- Request IDs flow through all services
- Service calls are logged with timing
- The gateway adds minimal overhead
- Errors include the full call chain

### Extending the demo

The demo provides a foundation for experimentation:

1. **Add a new service**: Create an inventory service that tracks stock levels
2. **Implement pub/sub**: Have orders publish events when created
3. **Add authentication**: Require JWT tokens for order creation
4. **Implement caching**: Cache product data in the orders service
5. **Add a database**: Replace in-memory storage with PostgreSQL

Example of adding an inventory service:

```crystal
@[Micro::Service(name: "inventory", version: "1.0.0")]
class InventoryService
  include Micro::ServiceBase

  struct Stock
    include JSON::Serializable
    getter product_id : String
    getter available : Int32
    getter reserved : Int32
  end

  @[Micro::Method]
  def check_availability(product_id : String, quantity : Int32) : Bool
    stock = get_stock(product_id)
    stock.available >= quantity
  end

  @[Micro::Method]
  def reserve_stock(product_id : String, quantity : Int32) : String
    # Reserve stock for order
    reservation_id = UUID.random.to_s
    # ... reservation logic ...
    reservation_id
  end

  # Subscribe to order events
  @[Micro::Subscribe(topic: "orders.created")]
  def handle_order_created(event : OrderCreatedEvent)
    event.items.each do |item|
      reserve_stock(item.product_id, item.quantity)
    end
  end
end
```

## Production considerations

While the demo uses in-memory storage and simplified error handling, production deployments should consider:

1. **Persistent storage**: Use databases for state persistence
2. **Configuration management**: Externalize configuration via environment variables or config files
3. **Security**: Implement proper authentication and authorization
4. **Monitoring**: Integrate with APM and logging systems
5. **Testing**: Add comprehensive unit and integration tests
6. **CI/CD**: Automate building, testing, and deployment
7. **Container orchestration**: Deploy with Kubernetes or similar
8. **Service mesh**: Consider Istio or Linkerd for advanced traffic management

The demo's architecture scales naturally to these production requirements while maintaining the same development experience.