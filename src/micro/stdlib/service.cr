require "../core/service"
require "../core/context"
require "../core/transport"
require "../core/codec"
require "../core/codec_selector"
require "../core/selector"
require "../core/pubsub"
require "../core/message_encoder"
require "./transports/http"
require "./codecs/json"
require "./server"
require "./discovery_client"
require "./pubsub/default"
require "log"

module Micro::Stdlib
  # Default service implementation with HTTP transport and JSON codec
  class Service < Micro::Core::Service::Impl
    @http_server : Server?
    @listener : Micro::Core::Listener?

    def start : Nil
      return if running?

      Log.info { "Starting service #{options.name} v#{options.version}" }

      # Initialize transport
      transport = options.transport || default_transport
      transport.start

      # Initialize PubSub if configured
      if ps = @pubsub
        ps.init unless ps.connected?
        Log.info { "PubSub initialized" }
      end

      # Create server
      server_options = Micro::Core::ServerOptions.new(
        address: ENV["MICRO_SERVER_ADDRESS"]? || "0.0.0.0:8080",
        advertise: ENV["MICRO_ADVERTISE_ADDRESS"]?
      )

      @http_server = server = Server.new(transport, server_options)

      # Set up request handler with codec selector
      codec_selector = Micro::Core::CodecSelector.new(default_codec: options.codec || default_codec)

      server.handle do |request|
        handle_request(request, codec_selector)
      end

      # Start server
      server.start
      @running = true

      # Register with registry if configured
      if registry = options.registry
        begin
          # Get the advertise address from server
          advertise_addr = server.advertise_address
          parts = advertise_addr.split(":")
          address = parts.first
          port = (parts.last? || "8080").to_i

          metadata = options.metadata.dup
          metadata["endpoints"] = @handlers.keys.join(",")

          service_def = Micro::Core::Registry::Service.new(
            name: options.name,
            version: options.version,
            metadata: metadata,
            nodes: [
              Micro::Core::Registry::Node.new(
                id: "#{options.name}-#{UUID.random}",
                address: address,
                port: port,
                metadata: HTTP::Headers.new
              ),
            ]
          )

          registry.register(service_def)
        rescue ex
          Log.warn { "Failed to register service: #{ex.message}" }
        end
      end

      Log.info { "Service started on #{server.address}" }
    end

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
        begin
          registry.deregister(
            Micro::Core::Registry::Service.new(
              name: options.name,
              version: options.version,
              metadata: HTTP::Headers.new,
              nodes: [] of Micro::Core::Registry::Node
            )
          )
        rescue ex
          Log.warn { "Failed to deregister service: #{ex.message}" }
        end
      end

      # Stop server
      @http_server.try(&.stop)
      @running = false

      Log.info { "Service stopped" }
    end

    private def handle_request(request : Micro::Core::TransportRequest, codec_selector : Micro::Core::CodecSelector) : Micro::Core::TransportResponse
      # Find handler for endpoint
      handler = @handlers[request.method]?

      unless handler
        # Use Accept header to determine response codec
        accept_header = request.headers["Accept"]? || "*/*"
        response_codec = codec_selector.select_by_accept(accept_header)

        error_info = Micro::Core::MessageEncoder.error_response(
          "Endpoint not found: #{request.method}",
          404,
          response_codec
        )
        return Micro::Core::TransportResponse.new(
          status: error_info[:status],
          body: error_info[:body],
          content_type: error_info[:content_type],
          error: "Endpoint not found"
        )
      end

      # Create context
      ctx_request = Micro::Core::Request.new(
        service: request.service,
        endpoint: request.method,
        content_type: request.content_type,
        headers: HTTP::Headers.new.tap { |h| request.headers.each { |k, v| h[k] = v } },
        body: request.body
      )

      ctx_response = Micro::Core::Response.new
      context = Micro::Core::Context.new(ctx_request, ctx_response)

      begin
        # Select codecs for request/response
        accept_header = request.headers["Accept"]? || "*/*"
        request_codec = codec_selector.select_with_fallback(request.content_type, nil, request.body)
        response_codec = codec_selector.select_by_accept(accept_header)

        # Unmarshal request body if needed
        if request.body.size > 0
          ctx_request.body = Micro::Core::MessageEncoder.unmarshal(request.body, JSON::Any, request_codec)
        end

        # Call handler
        handler.call(context)

        # Check if response has explicit content-type
        response_content_type = ctx_response.headers["Content-Type"]?
        if response_content_type
          # Use explicitly set content type
          response_codec = codec_selector.select_by_content_type(response_content_type)
        end

        # Marshal response body if needed
        response_body = Micro::Core::MessageEncoder.response_body_to_bytes(ctx_response.body, response_codec)

        Micro::Core::TransportResponse.new(
          status: ctx_response.status,
          body: response_body,
          content_type: response_codec.content_type,
          headers: ctx_response.headers.to_h.transform_values(&.first)
        )
      rescue ex
        Log.error(exception: ex) { "Error handling request" }

        # Use Accept header for error response
        accept_header = request.headers["Accept"]? || "*/*"
        error_codec = codec_selector.select_by_accept(accept_header)

        error_info = Micro::Core::MessageEncoder.error_response(
          ex.message || "Internal server error",
          500,
          error_codec
        )
        Micro::Core::TransportResponse.new(
          status: error_info[:status],
          body: error_info[:body],
          content_type: error_info[:content_type],
          error: ex.message || "Internal server error"
        )
      end
    end

    private def default_transport : Micro::Core::Transport
      Transports::HTTPTransport.new(
        Micro::Core::Transport::Options.new
      )
    end

    private def default_codec : Micro::Core::Codec
      Codecs::JSON.new
    end

    # Create a client with service discovery support
    def client(selector : Micro::Core::Selector? = nil) : Micro::Core::Client
      transport = options.transport || default_transport

      if registry = options.registry
        # Use discovery client when registry is available
        DiscoveryClient.new(transport, registry, selector || Micro::Core::RoundRobinSelector.new)
      else
        # Fall back to basic client
        Client.new(transport)
      end
    end
  end
end
