require "micro"
require "micro/gateway"
require "./services/catalog"
require "./services/orders"
require "./utilities/config"

# Single-process dev runner using a shared in-memory registry
registry = DemoConfig.shared_registry

# Start services with shared registry
catalog_opts = DemoConfig.service_options("catalog", "CATALOG_ADDR", "0.0.0.0:8081", registry)
orders_opts = DemoConfig.service_options("orders", "ORDERS_ADDR", "0.0.0.0:8082", registry)

catalog = CatalogService.new(catalog_opts)
orders = OrderService.new(orders_opts)

catalog.start_async
orders.start_async

# Build gateway against the same registry
gateway_builder = Micro::Gateway::Builder.new
gateway_builder.name("demo-gateway")
gateway_builder.version("1.0.0")
gateway_builder.host(ENV["GATEWAY_HOST"]? || "0.0.0.0")
gateway_builder.port((ENV["GATEWAY_PORT"]? || "8080").to_i)
gateway_builder.registry(registry)
gateway_builder.config.enable_docs = true
gateway_builder.config.docs_path = "/api/docs"
gateway_builder.config.enable_metrics = true
gateway_builder.config.metrics_path = "/metrics"
gateway_builder.health_check do
  services = gateway_builder.config.services.keys.map { |n| {n, true} }.to_h
  Micro::Gateway::HealthCheckResponse.new(
    status: :ok,
    services: services,
    uptime: 0.0
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

gateway = gateway_builder.build

# Trap termination, shut down services and gateway together
quit = Channel(Nil).new
shutdown = false
Process.on_terminate do |_|
  unless shutdown
    shutdown = true
    catalog.shutdown
    orders.shutdown
    gateway.shutdown
    quit.send(nil) rescue nil
  end
end

gateway.run
quit.receive
