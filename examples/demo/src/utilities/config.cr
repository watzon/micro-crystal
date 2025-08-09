require "micro"

module DemoConfig
  @@shared_registry : Micro::Core::Registry::Base?

  # Default registry for separate processes (memory or consul via env)
  def self.registry : Micro::Core::Registry::Base
    if addr = ENV["CONSUL_ADDR"]?
      Micro::Registries.consul(Micro::Core::Registry::Options.new(type: "consul", addresses: [addr]))
    else
      Micro::Registries.memory
    end
  end

  # Shared in-process registry (for dev runner)
  def self.shared_registry : Micro::Core::Registry::Base
    @@shared_registry ||= (ENV["CONSUL_ADDR"]? ? registry : Micro::Registries.memory)
  end

  # Helper to build service options
  def self.service_options(name : String, address_env : String, default_addr : String, registry : Micro::Core::Registry::Base) : Micro::ServiceOptions
    Micro::ServiceOptions.new(
      name: name,
      registry: registry,
      server_options: Micro::ServerOptions.new(address: ENV[address_env]? || default_addr)
    )
  end
end
