# Single module that provides all service functionality
# This combines Service base class behavior with macros for registration and method routing

require "./core/service"
require "./core/context"
require "./core/transport"
require "./core/codec"
require "./core/codec_selector"
require "./core/selector"
require "./core/pubsub"
require "./core/registry_store"
require "./stdlib/transports/http"
require "./stdlib/codecs/json"
require "./stdlib/server"
require "./stdlib/discovery_client"
require "./stdlib/pubsub/default"
require "./stdlib/brokers/memory"
require "./macros/registerable"
require "./macros/method_routing"
require "./macros/handler_config"
require "./macros/error_handling"
require "./macros/subscription_macros"
require "./macros/middleware_support"
require "log"
require "uuid"

module Micro
  # Single module that provides complete service functionality
  # Just include this to get everything needed for a service
  module ServiceBase
    macro included
      # Include all the necessary functionality
      include ::Micro::Macros::Registerable
      include ::Micro::Macros::MethodRouting
      include ::Micro::Macros::HandlerConfig
      include ::Micro::Macros::SubscriptionMacros
      include ::Micro::Macros::MiddlewareSupport

      # Instance variables needed by service implementation
      @running = false
      @handlers = {} of String => Proc(::Micro::Core::Context, Nil)
      @subscriptions = [] of ::Micro::Core::PubSub::Subscription
      @pubsub : ::Micro::Core::PubSub::Base?
      @http_server : ::Micro::Stdlib::Server?
      @listener : ::Micro::Core::Listener?
      @shutdown_channel = Channel(Nil).new
      @shutdown_hooks = [] of -> Nil
      @blocking_mode = false

      # ServiceBase included marker
      SERVICE_BASE_INCLUDED = true

      # Getters
      getter? running : Bool = false

      # Options getter - returns the stored options
      def options : ::Micro::Core::Service::Options
        @options
      end

      # Initialize with options, using annotation values as defaults
      def initialize(options : ::Micro::Core::Service::Options? = nil)
        @options = options || default_options
        @handlers = {} of String => Proc(::Micro::Core::Context, Nil)
        @subscriptions = [] of ::Micro::Core::PubSub::Subscription
        @running = false
        @pubsub = nil
        @http_server = nil
        @listener = nil
        @shutdown_channel = Channel(Nil).new
        @shutdown_hooks = [] of -> Nil
        @blocking_mode = false
      end

      # Default options using annotation values
      private def default_options
        if self.class.responds_to?(:service_metadata)
          metadata = self.class.service_metadata
          ::Micro::Core::Service::Options.new(
            name: metadata[:name] || self.class.name.downcase.gsub(/service$/, ""),
            version: metadata[:version] || "1.0.0",
            metadata: HTTP::Headers.new,
            transport: default_transport,
            codec: default_codec,
            registry: ::Micro::Core::RegistryStore.default_registry,
            server_options: ::Micro::Core::ServerOptions.new(
              address: ENV["MICRO_SERVER_ADDRESS"]? || "0.0.0.0:8080",
              advertise: ENV["MICRO_ADVERTISE_ADDRESS"]?
            )
          )
        else
          # Fallback if no annotation
          ::Micro::Core::Service::Options.new(
            name: self.class.name.downcase.gsub(/service$/, ""),
            version: "1.0.0",
            metadata: HTTP::Headers.new,
            transport: default_transport,
            codec: default_codec,
            registry: ::Micro::Core::RegistryStore.default_registry,
            server_options: ::Micro::Core::ServerOptions.new(
              address: ENV["MICRO_SERVER_ADDRESS"]? || "0.0.0.0:8080",
              advertise: ENV["MICRO_ADVERTISE_ADDRESS"]?
            )
          )
        end
      end

      # Service lifecycle methods

      def start : Nil
        return if running?

        Log.info { "Starting service #{options.name} v#{options.version}" }

        # Initialize transport
        transport = options.transport || default_transport
        transport.start

        # Initialize PubSub if configured (or create default)
        pubsub = @pubsub ||= options.pubsub || default_pubsub
        pubsub.init unless pubsub.connected?
        Log.info { "PubSub initialized" }

        # Create server
        server_options = options.server_options || ::Micro::Core::ServerOptions.new(
          address: ENV["MICRO_SERVER_ADDRESS"]? || "0.0.0.0:8080",
          advertise: ENV["MICRO_ADVERTISE_ADDRESS"]?
        )

        @http_server = server = ::Micro::Stdlib::Server.new(transport, server_options)

        # Set up request handler with codec selector
        codec_selector = ::Micro::Core::CodecSelector.new(default_codec: options.codec || default_codec)

        server.handle do |request|
          handle_request(request, codec_selector)
        end

        # Start server
        server.start
        @running = true

        # Auto-register if we have metadata and a register method
        if responds_to?(:register)
          # Pass the configured registry (if any) to the register method
          if registry = options.registry
            register(registry)
          else
            register
          end
        end

        # Register pub/sub subscriptions if available
        if self.responds_to?(:register_subscriptions)
          self.register_subscriptions
        end

        Log.info { "Service started on #{server.address}" }
      end

      def stop : Nil
        return unless running?

        Log.info { "Stopping service #{options.name}" }

        # Run shutdown hooks first
        @shutdown_hooks.each do |hook|
          begin
            hook.call
          rescue ex
            Log.error(exception: ex) { "Error in shutdown hook" }
          end
        end

        # Auto-deregister if registered
        if responds_to?(:deregister) && options.auto_deregister
          # Pass the configured registry (if any) to the deregister method
          if registry = options.registry
            deregister(registry)
          else
            deregister
          end
        end

        # Unregister pub/sub subscriptions if available
        if self.responds_to?(:unregister_subscriptions)
          self.unregister_subscriptions
        end

        # Unsubscribe any remaining PubSub subscriptions
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

        # Stop server
        @http_server.try(&.stop)
        @running = false

        Log.info { "Service stopped" }
      end

      # Run the service with optional signal handling (blocking)
      def run(trap_signals : Bool = true) : Nil
        @blocking_mode = true
        start

        if trap_signals && !ENV["MICRO_TEST"]?
          setup_signal_handlers
        end

        # Block until shutdown is requested
        wait_for_shutdown
      end

      def self.run(options : ::Micro::Core::Service::Options? = nil)
        service = new(options)
        service.run
      end

      # Non-blocking start (for advanced usage)
      # Use this when you want to manage the service lifecycle manually
      def start_async : Nil
        start
      end

      # Request graceful shutdown
      def shutdown : Nil
        Log.info { "Shutdown requested for service #{options.name}" }

        if @blocking_mode
          # In blocking mode, signal the wait_for_shutdown method
          @shutdown_channel.send(nil) rescue nil
        else
          # In non-blocking mode, stop directly
          stop
        end
      end

      # Add a shutdown hook
      def on_shutdown(&block : -> Nil) : Nil
        @shutdown_hooks << block
      end

      # Wait for shutdown signal
      private def wait_for_shutdown : Nil
        @shutdown_channel.receive
        stop
      end

      # Setup signal handlers
      private def setup_signal_handlers : Nil
        shutdown_requested = false
        Process.on_terminate do |signal|
          unless shutdown_requested
            shutdown_requested = true
            Log.info { "Received signal #{signal}, shutting down..." }
            shutdown
          end
        end
      end

      # Handler registration (from Service::Impl)

      def handle(method : String, &block : ::Micro::Core::Context ->)
        @handlers[method] = block
      end

      # Client creation

      def client(selector : ::Micro::Core::Selector? = nil) : ::Micro::Core::Client
        transport = options.transport || default_transport

        if registry = options.registry
          # Use discovery client when registry is available
          ::Micro::Stdlib::DiscoveryClient.new(transport, registry, selector || ::Micro::Core::RoundRobinSelector.new)
        else
          # Fall back to basic client
          ::Micro::Stdlib::Client.new(transport)
        end
      end

      # PubSub methods

      def publish(topic : String, message : ::Micro::Core::Message) : Nil
        pubsub = @pubsub ||= options.pubsub || default_pubsub
        pubsub.publish(topic, message)
      end

      def subscribe(topic : String, &block : ::Micro::Core::Message ->) : ::Micro::Core::Subscription
        pubsub = @pubsub ||= options.pubsub || default_pubsub
        subscription = pubsub.subscribe(topic, &block)
        @subscriptions << subscription
        subscription
      end

      # Subscribe with a PubSub::Handler (used by @[Micro::Subscribe] annotations)
      def subscribe(topic : String, handler : ::Micro::Core::PubSub::Handler) : ::Micro::Core::PubSub::Subscription
        pubsub = @pubsub ||= options.pubsub || default_pubsub
        subscription = pubsub.subscribe(topic, handler)
        @subscriptions << subscription
        subscription
      end

      # Subscribe with queue group and handler (used by @[Micro::Subscribe] annotations)
      def subscribe(topic : String, queue_group : String, handler : ::Micro::Core::PubSub::Handler) : ::Micro::Core::PubSub::Subscription
        pubsub = @pubsub ||= options.pubsub || default_pubsub
        subscription = pubsub.subscribe(topic, queue_group, handler)
        @subscriptions << subscription
        subscription
      end

      # Publish a PubSub::Event
      def publish(topic : String, event : ::Micro::Core::PubSub::Event) : Nil
        pubsub = @pubsub ||= options.pubsub || default_pubsub
        pubsub.publish(topic, event)
      end

      # Private helper methods

      protected def handle_request(request : ::Micro::Core::TransportRequest, codec_selector : ::Micro::Core::CodecSelector) : ::Micro::Core::TransportResponse
        # Check if we have RPC handling
        if self.responds_to?(:handle_rpc)
          # Create context for RPC
          # Use actual service name from options instead of what's in the request
          ctx_request = ::Micro::Core::Request.new(
            service: options.name,
            endpoint: request.method,
            content_type: request.content_type,
            headers: HTTP::Headers.new.tap { |h| request.headers.each { |k, v| h[k] = v } },
            body: request.body
          )

          ctx_response = ::Micro::Core::Response.new
          context = ::Micro::Core::Context.new(ctx_request, ctx_response)

          # Handle RPC
          self.handle_rpc(context)

          # Convert response
          return ::Micro::Core::TransportResponse.new(
            status: ctx_response.status,
            body: case body = ctx_response.body
            when Bytes then body
            when nil   then Bytes.empty
            else
              codec = codec_selector.select_by_content_type(ctx_response.headers["Content-Type"]? || "application/json")
              codec.marshal(body)
            end,
            content_type: ctx_response.headers["Content-Type"]? || "application/json",
            headers: ctx_response.headers
          )
        end

        # Fall back to handler-based routing
        handler = @handlers[request.method]?

        unless handler
          accept_header = request.headers["Accept"]? || "*/*"
          response_codec = codec_selector.select_by_accept(accept_header)

          return ::Micro::Core::TransportResponse.new(
            status: 404,
            body: response_codec.marshal({"error" => "Endpoint not found: #{request.method}"}),
            content_type: response_codec.content_type,
            error: "Endpoint not found"
          )
        end

        # Create context
        # Use actual service name from options instead of what's in the request
        ctx_request = ::Micro::Core::Request.new(
          service: options.name,
          endpoint: request.method,
          content_type: request.content_type,
          headers: HTTP::Headers.new.tap { |h| request.headers.each { |k, v| h[k] = v } },
          body: request.body
        )

        ctx_response = ::Micro::Core::Response.new
        context = ::Micro::Core::Context.new(ctx_request, ctx_response)

        begin
          # Select codecs for request/response
          accept_header = request.headers["Accept"]? || "*/*"
          request_codec = codec_selector.select_with_fallback(request.content_type, nil, request.body)
          response_codec = codec_selector.select_by_accept(accept_header)

          # Unmarshal request body if needed
          if request.body.size > 0
            ctx_request.body = request_codec.unmarshal(request.body, JSON::Any)
          end

          # Call handler
          handler.call(context)

          # Check if response has explicit content-type
          response_content_type = ctx_response.headers["Content-Type"]?
          if response_content_type
            response_codec = codec_selector.select_by_content_type(response_content_type)
          end

          # Marshal response body if needed
          response_body = case body = ctx_response.body
                          when Bytes
                            body
                          when nil
                            Bytes.empty
                          else
                            response_codec.marshal(body)
                          end

          ::Micro::Core::TransportResponse.new(
            status: ctx_response.status,
            body: response_body,
            content_type: response_codec.content_type,
            headers: ctx_response.headers
          )
        rescue ex
          Log.error(exception: ex) { "Error handling request" }

          accept_header = request.headers["Accept"]? || "*/*"
          error_codec = codec_selector.select_by_accept(accept_header)

          ::Micro::Core::TransportResponse.new(
            status: 500,
            body: error_codec.marshal({"error" => ex.message || "Internal server error"}),
            content_type: error_codec.content_type,
            error: ex.message || "Internal server error"
          )
        end
      end

      private def default_transport : ::Micro::Core::Transport
        ::Micro::Stdlib::Transports::HTTPTransport.new(
          ::Micro::Core::Transport::Options.new
        )
      end

      private def default_codec : ::Micro::Core::Codec
        ::Micro::Stdlib::Codecs::JSON.new
      end

      private def default_pubsub : ::Micro::Core::PubSub::Base
        # Need to create with options that include a broker
        if broker = options.broker
          ::Micro::Stdlib::PubSub::Default.new(
            ::Micro::Core::PubSub::Options.new(
              broker: broker,
              codec: options.codec || default_codec,
              auto_connect: true
            )
          )
        else
          # Fall back to in-memory broker for development
          ::Micro::Stdlib::PubSub::Default.new(
            ::Micro::Core::PubSub::Options.new(
              broker: ::Micro::Stdlib::Brokers::MemoryBroker.new,
              codec: options.codec || default_codec,
              auto_connect: true
            )
          )
        end
      end
    end
  end
end
