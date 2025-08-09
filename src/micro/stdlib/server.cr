require "../core/transport"
require "../core/service"
require "../core/context"
require "../core/codec"
require "../core/utils/ip"
require "../core/middleware"
require "../core/fiber_tracker"
require "../core/message_encoder"

module Micro::Stdlib
  # HTTP-based server implementation
  class Server < Micro::Core::Server
    include Micro::Core::FiberTracker
    @listener : Micro::Core::Listener?
    @address : String?
    @running = false
    @middleware_chain : Micro::Core::MiddlewareChain
    @accept_fiber : Fiber?

    def initialize(@transport : Micro::Core::Transport, @options : Micro::Core::ServerOptions)
      super(@transport, @options)
      @middleware_chain = Micro::Core::MiddlewareChain.new
    end

    def start : Nil
      return if @running

      # Start the transport
      @transport.start

      # Create listener
      @listener = @transport.listen(@options.address)
      @address = @listener.try(&.address)
      @running = true

      Log.info { "Server listening on #{@address}" }

      # Accept connections in background
      @accept_fiber = track_fiber("server-accept-#{@address}") { accept_loop }
    end

    def stop : Nil
      return unless @running

      @running = false
      @listener.try(&.close)

      # Give accept loop a moment to exit after listener closes
      sleep 0.1.seconds

      # Shutdown all tracked connection handler fibers
      shutdown_fibers(1.second)

      @transport.stop

      Log.info { "Server stopped" }
    end

    def handle(handler : Micro::Core::RequestHandler) : Nil
      @handler = handler
    end

    def handle(&block : Micro::Core::TransportRequest -> Micro::Core::TransportResponse) : Nil
      @handler = block
    end

    def address : String
      @address || "not started"
    end

    # Returns the address to advertise for service discovery
    def advertise_address : String
      # If advertise is explicitly set, use it
      if advertise = @options.advertise
        return advertise
      end

      # If MICRO_ADVERTISE_ADDRESS is set, use it
      if env_advertise = ENV["MICRO_ADVERTISE_ADDRESS"]?
        return env_advertise
      end

      # Otherwise, extract from bound address
      bound_addr = address
      return bound_addr if bound_addr == "not started"

      # Parse host and port
      host, port = Micro::Core::Utils::IP.parse_host_port(bound_addr)

      # Extract actual IP if needed
      actual_host = Micro::Core::Utils::IP.extract(host)

      "#{actual_host}:#{port}"
    end

    # Add middleware to the server
    def use(middleware : Micro::Core::Middleware) : self
      @middleware_chain.use(middleware)
      self
    end

    # Add multiple middleware at once
    def use(*middlewares : Micro::Core::Middleware) : self
      @middleware_chain.use(*middlewares)
      self
    end

    private def accept_loop
      listener = @listener
      return unless listener

      while @running
        begin
          # Accept with timeout to allow checking @running
          socket = listener.accept(1.second)
          next unless socket

          # Handle connection in new fiber
          # Use local variable to satisfy compiler's nil check
          conn = socket
          track_fiber("server-conn-#{conn.object_id}") do
            handle_connection(conn)
          end
        rescue ex : Micro::Core::TransportError
          if ex.code == Micro::Core::ErrorCode::ConnectionReset
            # Listener was closed, exit gracefully
            break
          else
            Log.error { "Error accepting connection: #{ex.message}" }
          end
        rescue ex
          Log.error { "Unexpected error in accept loop: #{ex.message}" }
        end
      end
    end

    private def handle_connection(socket : Micro::Core::Socket)
      # Receive the request message
      message = socket.receive

      # Convert transport message to service request
      request = Micro::Core::TransportRequest.new(
        service: message.target || "unknown",
        method: message.endpoint || "/",
        body: message.body,
        content_type: message.headers["Content-Type"]? || "application/octet-stream",
        headers: message.headers
      )

      # Create context for the request
      context = Micro::Core::Context.new(
        Micro::Core::Request.new(
          service: request.service,
          endpoint: request.method,
          content_type: request.content_type,
          headers: request.headers,
          body: request.body
        ),
        Micro::Core::Response.new
      )

      # Execute middleware chain with final handler
      if @middleware_chain.empty?
        # No middleware, call handler directly
        if @handler
          response = @handler.not_nil!.call(request)
        else
          error_info = Micro::Core::MessageEncoder.error_response("No handler registered", 404)
          response = Micro::Core::TransportResponse.new(
            status: error_info[:status],
            body: error_info[:body],
            content_type: error_info[:content_type]
          )
        end
      else
        # Execute middleware chain
        @middleware_chain.execute(context) do |ctx|
          # Final handler
          if @handler
            transport_response = @handler.not_nil!.call(request)
            # Copy transport response to context response
            ctx.response.status = transport_response.status
            ctx.response.body = transport_response.body
            ctx.response.headers.merge!(transport_response.headers)
          else
            ctx.response.status = 404
            ctx.response.body = {"error" => "No handler registered"}
          end
        end

        # Convert context response to transport response
        response_body = Micro::Core::MessageEncoder.response_body_to_bytes(context.response.body)

        response = Micro::Core::TransportResponse.new(
          status: context.response.status,
          body: response_body,
          content_type: context.response.headers["Content-Type"]? || "application/json",
          headers: context.response.headers
        )
      end

      # Convert response to transport message
      # Create headers with merged values
      merged_headers = HTTP::Headers.new
      response.headers.each do |key, values|
        values.each { |value| merged_headers.add(key, value) }
      end
      merged_headers["Content-Type"] = response.content_type
      merged_headers["X-Status-Code"] = response.status.to_s

      response_message = Micro::Core::Message.new(
        body: response.body,
        type: response.error? ? Micro::Core::MessageType::Error : Micro::Core::MessageType::Response,
        headers: merged_headers,
        id: message.id
      )

      # Send response
      socket.send(response_message)
    rescue ex
      Log.error { "Error handling connection: #{ex.message}" }

      # Try to send error response
      begin
        error_headers = HTTP::Headers.new
        error_headers["Content-Type"] = "application/json"
        error_response = Micro::Core::Message.new(
          body: Micro::Core::MessageEncoder.error_bytes(ex.message || "Internal server error"),
          type: Micro::Core::MessageType::Error,
          headers: error_headers
        )
        socket.send(error_response)
      rescue
        # Ignore errors sending error response
      end
    ensure
      socket.close unless socket.closed?
    end

    @handler : Micro::Core::RequestHandler?
  end
end
