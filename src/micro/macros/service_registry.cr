# Service Registry for compile-time service tracking
# This module provides macros to automatically register services
# that are annotated with @[Micro::Service]

module Micro::Macros
  module ServiceRegistry
    # Hook that runs when a module/class includes this
    macro included
      # Add a finished hook to process annotations
      macro finished
        \{% if @type.annotation(::Micro::Service) %}
          \{% service_ann = @type.annotation(::Micro::Service) %}

          # Extract service metadata from annotation using direct access
          \{% service_name = service_ann[:name] %}
          \{% service_version = service_ann[:version] %}
          \{% service_namespace = service_ann[:namespace] %}
          \{% service_description = service_ann[:description] %}
          \{% service_metadata = service_ann[:metadata] %}

          # Debug: Print what we found
          \{% if service_name %}
            # puts "Found name in annotation: \{{service_name}}"
          \{% else %}
            # puts "No name found in annotation"
          \{% end %}

          # Default values if not provided
          \{% service_name = service_name || @type.name.downcase.gsub(/service$/, "").stringify %}
          \{% service_version = service_version || "1.0.0" %}

          # Note: We can't actually store compile-time data in a constant
          # Instead, we'll generate a method that returns the metadata

          # Generate service metadata accessor
          def self.service_metadata
            {
              name: \{{service_name}},
              version: \{{service_version}},
              namespace: \{{service_namespace}},
              description: \{{service_description}},
              metadata: \{{service_metadata}},
              type: \{{@type.stringify}}
            }
          end

          # Store registered node ID for deregistration
          @registered_node_id : String? = nil

          # Generate register method
          def register(registry : ::Micro::Core::Registry::Base? = nil)
            registry ||= ::Micro::Core::RegistryStore.default_registry

            service = ::Micro::Core::Registry::Service.new(
              name: self.class.service_metadata[:name],
              version: self.class.service_metadata[:version],
              metadata: \{{service_metadata}} || {} of String => String,
              nodes: [] of ::Micro::Core::Registry::Node
            )

            # Add the current node
            address_with_port = @options.server_options.try(&.advertise) || @options.server_options.try(&.address) || "localhost:8080"
            host, port_str = address_with_port.includes?(":") ? address_with_port.split(":", 2) : [address_with_port, "8080"]
            port = port_str.to_i

            node_id = UUID.random.to_s
            @registered_node_id = node_id

            node = ::Micro::Core::Registry::Node.new(
              id: node_id,
              address: host,
              port: port,
              metadata: {} of String => String
            )

            service.nodes << node

            # Register with the registry
            registry.register(service)

            Log.info { "Registered service #{self.class.service_metadata[:name]} v#{self.class.service_metadata[:version]} with registry" }
          end

          # Generate deregister method
          def deregister(registry : ::Micro::Core::Registry::Base? = nil)
            registry ||= ::Micro::Core::RegistryStore.default_registry

            return unless @registered_node_id

            service = ::Micro::Core::Registry::Service.new(
              name: self.class.service_metadata[:name],
              version: self.class.service_metadata[:version],
              metadata: {} of String => String,
              nodes: [] of ::Micro::Core::Registry::Node
            )

            # Add the node with the stored ID for proper deregistration
            if node_id = @registered_node_id
              node = ::Micro::Core::Registry::Node.new(
                id: node_id,
                address: "dummy",  # MemoryRegistry only checks ID
                port: 0,
                metadata: {} of String => String
              )
              service.nodes << node
            end

            registry.deregister(service)
            @registered_node_id = nil

            Log.info { "Deregistered service #{self.class.service_metadata[:name]} v#{self.class.service_metadata[:version]} from registry" }
          end

          # Override stop to automatically deregister
          def stop : Nil
            deregister if @options.auto_deregister
            super
          end
        \{% end %}
      end
    end
  end
end
