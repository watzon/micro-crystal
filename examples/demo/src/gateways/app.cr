require "micro"
require "micro/gateway"
require "../services/catalog"
require "../services/orders"
require "../utilities/config"

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

  def self.run
    build_gateway.run
  end
end
