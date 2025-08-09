require "../../spec_helper"
require "../../../src/micro/core/registry"
require "../../../src/micro/stdlib/registries/memory_registry"

describe Micro::Core::Registry do
  describe "Node" do
    it "creates a node with required fields" do
      node = Micro::Core::Registry::Node.new(
        id: "node-1",
        address: "127.0.0.1",
        port: 8080
      )

      node.id.should eq("node-1")
      node.address.should eq("127.0.0.1")
      node.port.should eq(8080)
      node.metadata.should be_empty
    end

    it "creates a node with metadata" do
      metadata = {"region" => "us-west", "zone" => "a"}
      node = Micro::Core::Registry::Node.new(
        id: "node-1",
        address: "127.0.0.1",
        port: 8080,
        metadata: metadata
      )

      node.metadata.should eq(metadata)
    end

    it "converts to hash" do
      node = Micro::Core::Registry::Node.new(
        id: "node-1",
        address: "127.0.0.1",
        port: 8080,
        metadata: {"dc" => "us-west"}
      )

      hash = node.to_h
      hash["id"].should eq("node-1")
      hash["address"].should eq("127.0.0.1")
      hash["port"].should eq(8080)
      hash["metadata"].should eq({"dc" => "us-west"})
    end
  end

  describe "Service" do
    it "creates a service with required fields" do
      service = Micro::Core::Registry::Service.new(name: "api.users")

      service.name.should eq("api.users")
      service.version.should eq("*")
      service.metadata.should be_empty
      service.nodes.should be_empty
    end

    it "creates a service with all fields" do
      nodes = [
        Micro::Core::Registry::Node.new("node-1", "127.0.0.1", 8080),
        Micro::Core::Registry::Node.new("node-2", "127.0.0.2", 8080),
      ]

      service = Micro::Core::Registry::Service.new(
        name: "api.users",
        version: "1.0.0",
        metadata: {"protocol" => "grpc"},
        nodes: nodes
      )

      service.name.should eq("api.users")
      service.version.should eq("1.0.0")
      service.metadata.should eq({"protocol" => "grpc"})
      service.nodes.size.should eq(2)
    end
  end

  describe "MemoryRegistry" do
    it "registers and retrieves services" do
      options = Micro::Core::Registry::Options.new
      registry = Micro::Stdlib::Registries::MemoryRegistry.new(options)

      service = Micro::Core::Registry::Service.new(
        name: "test.service",
        version: "1.0.0",
        nodes: [
          Micro::Core::Registry::Node.new("node-1", "127.0.0.1", 8080),
        ]
      )

      registry.register(service)

      found = registry.get_service("test.service")
      found.size.should eq(1)
      found[0].name.should eq("test.service")
      found[0].version.should eq("1.0.0")
      found[0].nodes.size.should eq(1)
    end

    it "filters services by version" do
      options = Micro::Core::Registry::Options.new
      registry = Micro::Stdlib::Registries::MemoryRegistry.new(options)

      service_v1 = Micro::Core::Registry::Service.new(
        name: "test.service",
        version: "1.0.0",
        nodes: [Micro::Core::Registry::Node.new("node-1", "127.0.0.1", 8080)]
      )

      service_v2 = Micro::Core::Registry::Service.new(
        name: "test.service",
        version: "2.0.0",
        nodes: [Micro::Core::Registry::Node.new("node-2", "127.0.0.2", 8080)]
      )

      registry.register(service_v1)
      registry.register(service_v2)

      # Get all versions
      all_versions = registry.get_service("test.service")
      all_versions.size.should eq(2)

      # Get specific version
      v1_only = registry.get_service("test.service", "1.0.0")
      v1_only.size.should eq(1)
      v1_only[0].version.should eq("1.0.0")
    end

    it "deregisters services" do
      options = Micro::Core::Registry::Options.new
      registry = Micro::Stdlib::Registries::MemoryRegistry.new(options)

      service = Micro::Core::Registry::Service.new(
        name: "test.service",
        version: "1.0.0",
        nodes: [Micro::Core::Registry::Node.new("node-1", "127.0.0.1", 8080)]
      )

      registry.register(service)
      registry.get_service("test.service").size.should eq(1)

      registry.deregister(service)
      registry.get_service("test.service").should be_empty
    end

    it "lists all services" do
      options = Micro::Core::Registry::Options.new
      registry = Micro::Stdlib::Registries::MemoryRegistry.new(options)

      service1 = Micro::Core::Registry::Service.new(
        name: "service.one",
        nodes: [Micro::Core::Registry::Node.new("node-1", "127.0.0.1", 8080)]
      )

      service2 = Micro::Core::Registry::Service.new(
        name: "service.two",
        nodes: [Micro::Core::Registry::Node.new("node-2", "127.0.0.2", 8080)]
      )

      registry.register(service1)
      registry.register(service2)

      all = registry.list_services
      all.size.should eq(2)
      all.map(&.name).sort!.should eq(["service.one", "service.two"])
    end

    it "watches for service changes" do
      options = Micro::Core::Registry::Options.new
      registry = Micro::Stdlib::Registries::MemoryRegistry.new(options)
      events = [] of Micro::Core::Registry::Event

      # Start watcher in a fiber
      watcher = registry.watch
      spawn do
        loop do
          event = watcher.next
          break unless event
          events << event
        end
      end

      # Give watcher time to start
      sleep 10.milliseconds

      # Register a service
      service = Micro::Core::Registry::Service.new(
        name: "watched.service",
        nodes: [Micro::Core::Registry::Node.new("node-1", "127.0.0.1", 8080)]
      )
      registry.register(service)

      # Give time for event to be processed
      sleep 10.milliseconds

      # Deregister the service
      registry.deregister(service)

      # Give time for event to be processed
      sleep 10.milliseconds

      # Stop watcher
      watcher.stop

      # Give final events time to process
      sleep 10.milliseconds

      events.size.should eq(2)
      events[0].type.should eq(Micro::Core::Registry::EventType::Create)
      events[0].service.name.should eq("watched.service")
      events[1].type.should eq(Micro::Core::Registry::EventType::Delete)
    end

    it "filters watched services" do
      options = Micro::Core::Registry::Options.new
      registry = Micro::Stdlib::Registries::MemoryRegistry.new(options)
      events = [] of Micro::Core::Registry::Event

      # Watch only for specific service
      watcher = registry.watch("target.service")
      spawn do
        loop do
          event = watcher.next
          break unless event
          events << event
        end
      end

      # Give watcher time to start
      sleep 10.milliseconds

      # Register different services
      other_service = Micro::Core::Registry::Service.new(
        name: "other.service",
        nodes: [Micro::Core::Registry::Node.new("node-1", "127.0.0.1", 8080)]
      )
      target_service = Micro::Core::Registry::Service.new(
        name: "target.service",
        nodes: [Micro::Core::Registry::Node.new("node-2", "127.0.0.2", 8080)]
      )

      registry.register(other_service)
      registry.register(target_service)

      # Stop watcher
      watcher.stop

      # Give events time to process
      sleep 10.milliseconds

      # Should only have events for target.service
      events.size.should eq(1)
      events[0].service.name.should eq("target.service")
    end
  end

  describe "Factory" do
    it "creates registries by name" do
      registry = Micro::Core::Registry::Factory.create("memory")
      registry.should be_a(Micro::Stdlib::Registries::MemoryRegistry)
    end

    it "lists available registry types" do
      available = Micro::Core::Registry::Factory.available
      available.should contain("memory")
    end

    it "raises for unknown registry type" do
      expect_raises(Micro::Core::Registry::RegistryError, "Unknown registry type: unknown") do
        Micro::Core::Registry::Factory.create("unknown")
      end
    end
  end
end
