# Enhanced routable module that includes handler configuration
# This combines all macro functionality for complete service generation

require "./registerable"
require "./method_routing"
require "./subscription_macros"
require "./handler_config"
require "./client_stubs"

module Micro::Macros
  # Enhanced module that includes all macro functionality
  # Use this for services that need handler configuration
  module EnhancedRoutable
    macro included
      # Include all functionality
      include ::Micro::Macros::Registerable
      include ::Micro::Macros::MethodRouting
      include ::Micro::Macros::SubscriptionMacros
      include ::Micro::Macros::HandlerConfig

      # Add server instance variable
      @server : ::Micro::Stdlib::Server? = nil
    end

    # Same start/stop implementation as Routable
    def start : Nil
      super

      if self.responds_to?(:register_subscriptions)
        self.register_subscriptions
      end

      if transport = @options.transport
        if self.class.responds_to?(:registered_methods) && self.responds_to?(:handle_rpc)
          server_options = @options.server_options || ::Micro::Core::ServerOptions.new(
            address: "localhost:0"
          )

          server = ::Micro::Stdlib::Server.new(transport, server_options)
          @server = server

          server.handle do |request|
            context_request = ::Micro::Core::Request.new(
              service: request.service,
              endpoint: request.method,
              content_type: request.content_type,
              body: request.body,
              headers: request.headers
            )

            context_response = ::Micro::Core::Response.new
            context = ::Micro::Core::Context.new(context_request, context_response)

            handle_rpc(context)

            ::Micro::Core::TransportResponse.new(
              status: context.response.status,
              body: if body = context.response.body
                case body
                when Bytes
                  body
                when String
                  body.to_slice
                when Hash, Array
                  body.to_json.to_slice
                else
                  body.to_s.to_slice
                end
              else
                Bytes.empty
              end,
              content_type: context.response.headers["Content-Type"]? || "application/json",
              headers: context.response.headers
            )
          end

          server.start

          Log.info { "Enhanced RPC server started with #{self.class.registered_methods.size} methods at #{server.address}" }
        end
      end
    end

    def stop : Nil
      if self.responds_to?(:unregister_subscriptions)
        self.unregister_subscriptions
      end

      @server.try(&.stop)
      super
    end

    def server_address : String?
      @server.try(&.address)
    end
  end
end
