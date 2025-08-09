# API Gateway module for micro-crystal
# Provides a unified entry point for microservices with routing,
# aggregation, and protocol translation capabilities

require "./gateway/config"
require "./gateway/route"
require "./gateway/route_builder"
require "./gateway/service_proxy"
require "./gateway/api_gateway"
require "./gateway/dsl"
require "./gateway/openapi"
require "./gateway/middleware/*"

module Micro::Gateway
  VERSION = "0.1.0"

  # Build a new API Gateway with DSL configuration
  def self.build(&) : APIGateway
    builder = Builder.new
    with builder yield
    builder.build
  end
end
