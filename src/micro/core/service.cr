require "./registry"
require "./broker"
require "./pubsub"
require "./transport"
require "./codec"

module Micro::Core
  # Service is the main facade interface for microservices
  # It provides a unified interface for service lifecycle management
  module Service
    # Options for configuring a service
    struct Options
      property name : String
      property version : String
      property metadata : HTTP::Headers
      property transport : Transport?
      property codec : Codec?
      property registry : Registry::Base?
      property broker : Broker::Base?
      property pubsub : PubSub::Base?
      property server_options : ServerOptions?
      property auto_deregister : Bool

      def initialize(
        @name : String,
        @version : String = "latest",
        @metadata : HTTP::Headers = HTTP::Headers.new,
        @transport : Core::Transport? = nil,
        @codec : Core::Codec? = nil,
        @registry : Core::Registry::Base? = nil,
        @broker : Core::Broker::Base? = nil,
        @pubsub : Core::PubSub::Base? = nil,
        @server_options : ServerOptions? = nil,
        @auto_deregister : Bool = true,
      )
      end
    end

    # Base service interface that all services must implement
    abstract class Base
      getter options : Options
      getter? running : Bool = false
      getter pubsub : Core::PubSub::Base?

      def initialize(@options : Options)
        @pubsub = options.pubsub
      end

      # Start the service
      abstract def start : Nil

      # Stop the service gracefully
      abstract def stop : Nil

      # Run the service (blocking)
      def run : Nil
        start

        # Block until signal received
        channel = Channel(Signal).new

        Signal::INT.trap { channel.send(Signal::INT) }
        Signal::TERM.trap { channel.send(Signal::TERM) }

        signal = channel.receive
        Log.info { "Received signal #{signal}, shutting down..." }

        stop
      end

      # Publish an event to a topic
      def publish(topic : String, event : Core::PubSub::Event) : Nil
        if ps = @pubsub
          ps.publish(topic, event)
        else
          raise "PubSub not configured for this service"
        end
      end

      # Subscribe to a topic
      def subscribe(topic : String, handler : Core::PubSub::Handler) : Core::PubSub::Subscription?
        if ps = @pubsub
          ps.subscribe(topic, handler)
        else
          raise "PubSub not configured for this service"
        end
      end

      # Subscribe to a topic with queue group
      def subscribe(topic : String, queue : String, handler : Core::PubSub::Handler) : Core::PubSub::Subscription?
        if ps = @pubsub
          ps.subscribe(topic, queue, handler)
        else
          raise "PubSub not configured for this service"
        end
      end
    end

    # Service implementation that handles the actual service logic
    class Impl < Base
      @handlers = {} of String => Handler
      @subscriptions = [] of Core::PubSub::Subscription

      # Register a handler for a specific endpoint
      def handle(endpoint : String, handler : Handler) : self
        @handlers[endpoint] = handler
        self
      end

      # Start the service
      def start : Nil
        return if running?

        Log.info { "Starting service #{options.name} v#{options.version}" }

        # Initialize transport
        transport = options.transport || default_transport

        # Initialize PubSub if configured
        if ps = @pubsub
          ps.init unless ps.connected?
          Log.info { "PubSub initialized" }
        end

        # Register with registry if configured
        if registry = options.registry
          registry.register(registry_service)
        end
        @running = true

        Log.info { "Service started successfully" }
      end

      # Stop the service gracefully
      def stop : Nil
        return unless running?

        Log.info { "Stopping service #{options.name}" }

        # Unsubscribe all PubSub subscriptions
        @subscriptions.each do |sub|
          begin
            sub.unsubscribe
          rescue ex
            Log.warn { "Failed to unsubscribe: #{ex.message}" }
          end
        end
        @subscriptions.clear

        # Disconnect PubSub if configured
        if ps = @pubsub
          ps.disconnect if ps.connected?
          Log.info { "PubSub disconnected" }
        end

        # Deregister from registry
        if registry = options.registry
          registry.deregister(registry_service)
        end

        @running = false

        Log.info { "Service stopped" }
      end

      # Override subscribe to track subscriptions
      def subscribe(topic : String, handler : Core::PubSub::Handler) : Core::PubSub::Subscription?
        if sub = super(topic, handler)
          @subscriptions << sub
          sub
        end
      end

      # Override subscribe with queue to track subscriptions
      def subscribe(topic : String, queue : String, handler : Core::PubSub::Handler) : Core::PubSub::Subscription?
        if sub = super(topic, queue, handler)
          @subscriptions << sub
          sub
        end
      end

      private def service_definition
        Service::Definition.new(
          name: options.name,
          version: options.version,
          metadata: options.metadata,
          endpoints: @handlers.keys
        )
      end

      private def registry_service
        # Convert service definition to registry service format
        # For now, we create a registry service without nodes
        # The registry implementation will handle adding the actual node information

        # Convert HTTP::Headers to Hash(String, String) for registry
        metadata = {} of String => String
        options.metadata.each do |key, values|
          metadata[key] = values.join(",")
        end
        metadata["endpoints"] = @handlers.keys.join(",")

        Registry::Service.new(
          name: options.name,
          version: options.version,
          metadata: metadata
        )
      end

      private def default_transport
        # This will be implemented when we have the HTTP transport
        raise NotImplementedError.new("Default transport not yet implemented")
      end

      private def default_codec
        # This will be implemented when we have the JSON codec
        raise NotImplementedError.new("Default codec not yet implemented")
      end
    end

    # Handler represents a request handler function
    alias Handler = Proc(Context, Nil)

    # Service definition for registry
    struct Definition
      property name : String
      property version : String
      property metadata : HTTP::Headers
      property endpoints : Array(String)

      def initialize(
        @name : String,
        @version : String,
        @metadata : HTTP::Headers,
        @endpoints : Array(String),
      )
      end
    end

    # Create a new service with the given options
    def self.new(options : Options) : Base
      Impl.new(options)
    end

    # Create a new service with a block for configuration
    def self.new(name : String, version : String = "latest") : Base
      options = Options.new(name: name, version: version)
      Impl.new(options)
    end
  end

  # Forward declarations for interfaces that will be defined later
  abstract class Codec; end

  module Registry; end

  module Broker; end

  module PubSub; end
end
