# Convenience require for stdlib testing helpers
require "./testing/service_harness"
require "./testing/gateway_test_client"
require "./testing/spec_macros"

module Micro::Stdlib::Testing
  # Runtime helper to build a gateway test client from a DSL block
  def self.build_gateway(&) : GatewayTestClient
    builder = Micro::Gateway::Builder.new
    with builder yield
    GatewayTestClient.new(builder.config)
  end
end

