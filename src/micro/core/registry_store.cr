# Global registry store for default registry instance
require "../stdlib/registries/memory_registry"
require "../stdlib/registries/consul"

module Micro::Core
  module RegistryStore
    @@default_registry : Registry::Base?

    # Get the default registry instance
    def self.default_registry : Registry::Base
      @@default_registry ||= begin
        # Try to use Consul if available, otherwise use memory registry
        if ENV["MICRO_REGISTRY"]? == "consul"
          Micro::Stdlib::Registries::ConsulRegistry.new(
            Registry::Options.new(
              addresses: [ENV["CONSUL_ADDRESS"]? || "localhost:8500"]
            )
          )
        else
          Micro::Stdlib::Registries::MemoryRegistry.new(Registry::Options.new)
        end
      end
    end

    # Set a custom default registry
    def self.default_registry=(registry : Registry::Base)
      @@default_registry = registry
    end

    # Reset the default registry (mainly for testing)
    def self.reset_default_registry
      @@default_registry = nil
    end
  end
end
