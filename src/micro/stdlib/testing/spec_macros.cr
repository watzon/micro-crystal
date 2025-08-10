module Micro::Stdlib::Testing
  # Simple in-memory registry for service harnesses
  module HarnessRegistry
    extend self

    @@mutex = Mutex.new
    @@harnesses = {} of String => ServiceHarness

    def register(name : String, harness : ServiceHarness) : Nil
      @@mutex.synchronize { @@harnesses[name] = harness }
    end

    def get(name : String) : ServiceHarness
      @@mutex.synchronize { @@harnesses[name]? } || raise "Harness not found: #{name}"
    end

    def fetch(name : String) : ServiceHarness?
      @@mutex.synchronize { @@harnesses[name]? }
    end

    # Fetch and raise if missing (non-nil return)
    def fetch!(name : String) : ServiceHarness
      get(name)
    end

    def clear : Nil
      @@mutex.synchronize { @@harnesses.clear }
    end
  end

  # Registry for gateway test clients
  module GatewayRegistry
    extend self

    @@mutex = Mutex.new
    @@clients = {} of String => GatewayTestClient

    def register(name : String, client : GatewayTestClient) : Nil
      @@mutex.synchronize { @@clients[name] = client }
    end

    def get(name : String = "gateway") : GatewayTestClient
      @@mutex.synchronize { @@clients[name]? } || raise "Gateway client not found: #{name}"
    end

    def fetch(name : String = "gateway") : GatewayTestClient?
      @@mutex.synchronize { @@clients[name]? }
    end

    # Fetch and raise if missing (non-nil return)
    def fetch!(name : String = "gateway") : GatewayTestClient
      get(name)
    end

    def clear : Nil
      @@mutex.synchronize { @@clients.clear }
    end
  end
end

# Top-level macro for defining a service harness in specs
macro harness(name, version = "latest", address = nil)
  %h = Micro::Stdlib::Testing::ServiceHarness.build({{name}}, {{version}}, {{address}}) do
    {{ yield }}
  end
  Micro::Stdlib::Testing::HarnessRegistry.register({{name}}, %h)
end

# Top-level macro to define a gateway and register a testing client
macro gateway(name)
  Micro::Stdlib::Testing::GatewayRegistry.register(
    {{name}},
    Micro::Stdlib::Testing.build_gateway do
      {{ yield }}
    end
  )
end

# Access a registered gateway test client by name (default: "gateway")
macro gateway_client(name)
  Micro::Stdlib::Testing::GatewayRegistry.get({{name}})
end
