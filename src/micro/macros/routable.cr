# Routable module combines service registration with method routing and subscriptions
# Include this module to get @[Micro::Service], @[Micro::Method], and @[Micro::Subscribe] processing

require "./registerable"
require "./method_routing"
require "./subscription_macros"

module Micro::Macros
  # Include this module in your service class to enable
  # service registration, method routing, and pub/sub functionality
  #
  # Example:
  # ```
  # @[Micro::Service(name: "calculator", version: "1.0.0")]
  # class CalculatorService < Micro::Core::Service::Impl
  #   include Micro::Macros::Routable
  #
  #   @[Micro::Method(name: "add")]
  #   def add(params : AddParams) : AddResult
  #     AddResult.new(params.a + params.b)
  #   end
  #
  #   @[Micro::Subscribe(topic: "user.created", queue_group: "calculator")]
  #   def handle_user_created(event : UserCreatedEvent)
  #     # Process event
  #   end
  # end
  # ```
  module Routable
    macro included
      # Include registration, routing, and subscription functionality
      include ::Micro::Macros::Registerable
      include ::Micro::Macros::MethodRouting
      include ::Micro::Macros::SubscriptionMacros

      # Add server instance variable
      @server : ::Micro::Stdlib::Server? = nil
    end

    # Override the service's start method to wire up RPC handler and subscriptions
    def start : Nil
      # Call parent start method
      super

      # Register pub/sub subscriptions if available
      {% if @type.methods.any?(&.annotation(::Micro::Subscribe)) %}
        register_subscriptions
      {% end %}

      # If we have a transport and registered methods, set up the handler
      if transport = @options.transport
        if self.class.responds_to?(:registered_methods) && self.responds_to?(:handle_rpc)
          # Create server with our RPC handler
          server_options = @options.server_options || ::Micro::Core::ServerOptions.new(
            address: "localhost:0" # Default to random port
          )

          server = ::Micro::Stdlib::Server.new(transport, server_options)
          @server = server

          # Set up the RPC handler
          server.handle do |request|
            # Create context from transport request
            context_request = ::Micro::Core::Request.new(
              service: request.service,
              endpoint: request.method,
              content_type: request.content_type,
              body: request.body,
              headers: request.headers
            )

            context_response = ::Micro::Core::Response.new
            context = ::Micro::Core::Context.new(context_request, context_response)

            # Handle the RPC call
            handle_rpc(context)

            # Convert context response back to transport response
            ::Micro::Core::TransportResponse.new(
              status: context.response.status,
              body: ::Micro::Core::MessageEncoder.response_body_to_bytes(context.response.body),
              content_type: context.response.headers["Content-Type"]? || "application/json",
              headers: context.response.headers
            )
          end

          # Start the server
          server.start

          Log.info { "RPC server started with #{self.class.registered_methods.size} methods at #{server.address}" }
        end
      end
    end

    # Override stop to also stop the server and unregister subscriptions
    def stop : Nil
      # Unregister pub/sub subscriptions if available
      {% if @type.methods.any?(&.annotation(::Micro::Subscribe)) %}
        unregister_subscriptions
      {% end %}

      @server.try(&.stop)
      super
    end

    # Expose server address for convenience
    def server_address : String?
      @server.try(&.address)
    end
  end
end
