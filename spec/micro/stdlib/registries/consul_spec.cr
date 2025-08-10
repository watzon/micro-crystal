require "../../../spec_helper"
require "../../../../src/micro/stdlib/registries/consul"
require "webmock"

describe Micro::Stdlib::Registries::ConsulRegistry do
  it "registers and deregisters a service (stubbed)" do
    options = Micro::Core::Registry::Options.new(type: "consul", addresses: ["127.0.0.1:8500"])
    registry = Micro::Stdlib::Registries::ConsulRegistry.new(options)

    # Stub Consul HTTP endpoints
    service = Micro::Core::Registry::Service.new(
      name: "stub.service",
      version: "1.0.0",
      nodes: [Micro::Core::Registry::Node.new("node-1", "127.0.0.1", 8080)]
    )

    # These endpoints vary by implementation; we keep it lightweight and lenient
    WebMock.stub(:put, /v1\/agent\/service\/register/).to_return(status: 200, body: "{}")
    WebMock.stub(:put, /v1\/agent\/service\/deregister/).to_return(status: 200, body: "{}")

    # Should not raise on register/deregister
    registry.register(service)
    registry.deregister(service)
  end
end


