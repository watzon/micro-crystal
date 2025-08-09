module Micro
  module Core
    # Registry provides service discovery and registration capabilities.
    # Implementations might include Consul, etcd, Kubernetes API, or in-memory registries.
    module Registry
      # Node represents an instance of a service
      class Node
        getter id : String
        getter address : String
        getter port : Int32
        getter metadata : Hash(String, String)

        def initialize(@id : String, @address : String, @port : Int32, @metadata = {} of String => String)
        end

        def to_h
          {
            "id"       => @id,
            "address"  => @address,
            "port"     => @port,
            "metadata" => @metadata,
          }
        end
      end

      # Service represents a collection of nodes for a service
      class Service
        getter name : String
        getter version : String
        getter metadata : Hash(String, String)
        getter nodes : Array(Node)

        def initialize(@name : String, @version : String = "*", @metadata = {} of String => String, @nodes = [] of Node)
        end

        def to_h
          {
            "name"     => @name,
            "version"  => @version,
            "metadata" => @metadata,
            "nodes"    => @nodes.map(&.to_h),
          }
        end
      end

      # Event types for service changes
      enum EventType
        Create
        Update
        Delete
      end

      # Event represents a service change event
      class Event
        getter type : EventType
        getter service : Service
        getter timestamp : Time

        def initialize(@type : EventType, @service : Service, @timestamp = Time.utc)
        end
      end

      # Watcher interface for monitoring service changes
      abstract class Watcher
        # Stop watching
        abstract def stop

        # Get next event (blocking)
        abstract def next : Event?
      end

      # Registry interface for service discovery
      abstract class Base
        # Register a service with the registry
        abstract def register(service : Service, ttl : Time::Span? = nil) : Nil

        # Deregister a service from the registry
        abstract def deregister(service : Service) : Nil

        # Get a service by name (optionally filtered by version)
        abstract def get_service(name : String, version : String = "*") : Array(Service)

        # List all services
        abstract def list_services : Array(Service)

        # Watch for service changes
        abstract def watch(service : String? = nil) : Watcher
      end

      # Registry errors
      class RegistryError < Exception; end

      class ServiceNotFoundError < RegistryError; end

      class RegistrationError < RegistryError; end

      class ConnectionError < RegistryError; end

      # Factory for creating registries
      module Factory
        @@registries = {} of String => Proc(Hash(String, String), Registry::Base)

        def self.register(name : String, &block : Hash(String, String) -> Registry::Base)
          @@registries[name] = block
        end

        def self.create(name : String, options = {} of String => String) : Registry::Base
          factory = @@registries[name]?
          raise RegistryError.new("Unknown registry type: #{name}") unless factory
          factory.call(options)
        end

        def self.available
          @@registries.keys
        end
      end

      # Options for configuring a registry
      struct Options
        property type : String
        property addresses : Array(String)
        property timeout : Time::Span
        property secure : Bool
        property tls_config : Hash(String, String)?

        def initialize(
          @type = "memory",
          @addresses = [] of String,
          @timeout = 30.seconds,
          @secure = false,
          @tls_config = nil,
        )
        end
      end
    end
  end
end
