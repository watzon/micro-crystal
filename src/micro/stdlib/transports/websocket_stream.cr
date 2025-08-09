require "../../core/transport"
require "../../core/fiber_tracker"
require "./websocket_transport"

module Micro::Stdlib::Transports
  # WebSocketStream provides bidirectional streaming over WebSocket
  class WebSocketStream < Micro::Core::Stream
    @socket : WebSocketConnection
    @closed : Bool = false
    @send_closed : Bool = false

    def initialize(@socket : WebSocketConnection, initial_metadata : HTTP::Headers = HTTP::Headers.new)
      @metadata = initial_metadata
    end

    # Send a message with a specific stream ID (for broadcast scenarios)
    def send_with_stream_id(body : Bytes, stream_id : String) : Nil
      raise Micro::Core::TransportError.new("Stream closed", Micro::Core::ErrorCode::ConnectionReset) if @closed

      # Create a message with the specified stream ID
      message = Micro::Core::Message.new(
        body: body,
        type: Micro::Core::MessageType::Event,
        headers: {"stream-id" => stream_id},
        id: UUID.random.to_s
      )

      @socket.send(message)
    end

    def send(body : Bytes) : Nil
      raise Micro::Core::TransportError.new("Stream closed", Micro::Core::ErrorCode::ConnectionReset) if @closed
      raise Micro::Core::TransportError.new("Send side closed", Micro::Core::ErrorCode::ConnectionReset) if @send_closed

      # Create a stream message
      headers = @metadata.dup
      headers["stream-id"] = @id

      message = Micro::Core::Message.new(
        body: body,
        type: Micro::Core::MessageType::Event,
        headers: headers,
        id: UUID.random.to_s
      )

      @socket.send(message)
    end

    def receive : Bytes
      raise Micro::Core::TransportError.new("Stream closed", Micro::Core::ErrorCode::ConnectionReset) if @closed

      loop do
        message = @socket.receive

        # Check if this message belongs to our stream
        if message.headers["stream-id"]? == @id
          # Check for stream control messages
          if message.headers["stream-control"]? == "close"
            @closed = true
            raise Micro::Core::TransportError.new("Stream closed by remote", Micro::Core::ErrorCode::ConnectionReset)
          elsif message.headers["stream-control"]? == "error"
            error_msg = message.headers["stream-error"]? || "Unknown stream error"
            raise Micro::Core::TransportError.new(error_msg, Micro::Core::ErrorCode::InternalError)
          end

          return message.body
        end
        # Ignore messages for other streams
      end
    end

    def receive(timeout : Time::Span) : Bytes?
      raise Micro::Core::TransportError.new("Stream closed", Micro::Core::ErrorCode::ConnectionReset) if @closed

      deadline = Time.monotonic + timeout

      loop do
        remaining = deadline - Time.monotonic
        return nil if remaining <= Time::Span.zero

        message = @socket.receive(remaining)
        return nil unless message

        # Check if this message belongs to our stream
        if message.headers["stream-id"]? == @id
          # Check for stream control messages
          if message.headers["stream-control"]? == "close"
            @closed = true
            raise Micro::Core::TransportError.new("Stream closed by remote", Micro::Core::ErrorCode::ConnectionReset)
          elsif message.headers["stream-control"]? == "error"
            error_msg = message.headers["stream-error"]? || "Unknown stream error"
            raise Micro::Core::TransportError.new(error_msg, Micro::Core::ErrorCode::InternalError)
          end

          return message.body
        end
        # Continue loop for messages from other streams
      end
    end

    def close : Nil
      return if @closed
      @closed = true

      # Send close control message
      begin
        close_msg = Micro::Core::Message.new(
          body: Bytes.empty,
          type: Micro::Core::MessageType::Event,
          headers: HTTP::Headers{
            "stream-id"      => @id,
            "stream-control" => "close",
          },
          id: UUID.random.to_s
        )
        @socket.send(close_msg)
      rescue
        # Ignore send errors on close
      end
    end

    def closed? : Bool
      @closed || @socket.closed?
    end

    def close_send : Nil
      return if @send_closed
      @send_closed = true

      # Send close-send control message
      begin
        close_msg = Micro::Core::Message.new(
          body: Bytes.empty,
          type: Micro::Core::MessageType::Event,
          headers: HTTP::Headers{
            "stream-id"      => @id,
            "stream-control" => "close-send",
          },
          id: UUID.random.to_s
        )
        @socket.send(close_msg)
      rescue
        # Ignore send errors
      end
    end

    def send_closed? : Bool
      @send_closed
    end
  end

  # WebSocketClient with streaming support
  class WebSocketClient < Micro::Core::Client
    def initialize(transport : WebSocketTransport)
      super(transport)
    end

    def call(request : Micro::Core::TransportRequest) : Micro::Core::TransportResponse
      # For WebSocket, we dial a connection and send the request
      socket = transport.dial(request.service).as(WebSocketConnection)

      begin
        # Convert request to message
        headers = request.headers.dup
        headers["Content-Type"] = request.content_type
        headers["Service"] = request.service
        headers["Method"] = request.method

        message = Micro::Core::Message.new(
          body: request.body,
          type: Micro::Core::MessageType::Request,
          headers: headers,
          target: request.service,
          endpoint: request.method
        )

        # Send request
        socket.send(message)

        # Wait for response with timeout
        response = socket.receive(request.timeout)

        if response.nil?
          return Micro::Core::TransportResponse.new(
            status: 504,
            error: "Request timeout"
          )
        end

        # Convert message to response
        status = response.headers["Status"]?.try(&.to_i) || 200
        content_type = response.headers["Content-Type"]? || "application/json"

        Micro::Core::TransportResponse.new(
          status: status,
          body: response.body,
          content_type: content_type,
          headers: response.headers,
          error: response.type == Micro::Core::MessageType::Error ? String.new(response.body) : nil
        )
      ensure
        socket.close
      end
    end

    def call(service : String, method : String, body : Bytes, opts : Micro::Core::CallOptions? = nil) : Micro::Core::TransportResponse
      opts ||= Micro::Core::CallOptions.new

      request = Micro::Core::TransportRequest.new(
        service: service,
        method: method,
        body: body,
        headers: opts.headers,
        timeout: opts.timeout
      )

      call(request)
    end

    def stream(service : String, method : String, opts : Micro::Core::CallOptions? = nil) : Micro::Core::Stream
      opts ||= Micro::Core::CallOptions.new

      # Construct full WebSocket URL with path
      service_url = service.ends_with?("/") ? service[0...-1] : service
      full_url = "#{service_url}#{method}"

      # Dial persistent connection for streaming
      socket = transport.dial(full_url).as(WebSocketConnection)

      # Send initial stream request
      stream_id = UUID.random.to_s
      headers = opts.headers.dup
      headers["Service"] = service
      headers["Method"] = method
      headers["Stream"] = "true"
      headers["stream-id"] = stream_id

      init_msg = Micro::Core::Message.new(
        body: Bytes.empty,
        type: Micro::Core::MessageType::Request,
        headers: headers,
        target: service,
        endpoint: method
      )

      socket.send(init_msg)

      # Create stream with initial metadata and the same stream ID
      stream = WebSocketStream.new(socket, {
        "Service"   => service,
        "Method"    => method,
        "stream-id" => stream_id,
      })
      stream.id = stream_id # Use our negotiated stream ID
      stream
    end
  end

  # WebSocketServer with streaming support
  class WebSocketStreamingServer < Micro::Core::StreamingServer
    include Micro::Core::FiberTracker

    @listener : WebSocketListener?
    @handlers = {} of String => Micro::Core::RequestHandler
    @stream_handlers = {} of String => Micro::Core::StreamHandler

    def initialize(transport : WebSocketTransport, options : Micro::Core::ServerOptions)
      super(transport, options)
    end

    def start : Nil
      return if @listener

      listener = transport.listen(options.address).as(WebSocketListener)
      listener.start
      @listener = listener

      # Start accepting connections
      spawn accept_loop
    end

    def stop : Nil
      @listener.try(&.close)
      @listener = nil
    end

    def handle(handler : Micro::Core::RequestHandler) : Nil
      @handlers["*"] = handler
    end

    def handle_stream(path : String, handler : Micro::Core::StreamHandler) : Nil
      @stream_handlers[path] = handler
    end

    def remove_stream_handler(path : String) : Nil
      @stream_handlers.delete(path)
    end

    def address : String
      @listener.try(&.address) || options.address
    end

    private def accept_loop
      listener = @listener
      return unless listener

      loop do
        begin
          socket = listener.accept.as(WebSocketConnection)
          spawn handle_connection(socket)
        rescue ex : Micro::Core::TransportError
          break if ex.message.try(&.includes?("closed"))
        rescue ex
          # Log error and continue
        end
      end
    end

    private def handle_connection(socket : WebSocketConnection)
      stream_handled = false

      loop do
        begin
          message = socket.receive

          # Check if this is a streaming request
          if message.headers["Stream"]? == "true"
            handle_stream_request(socket, message)
            # For streaming requests, the handler takes over the socket
            # so we should exit this loop
            stream_handled = true
            break
          else
            handle_request(socket, message)
          end
        rescue ex : Micro::Core::TransportError
          break if ex.message.try(&.includes?("closed"))
        rescue ex
          # Send error response
          error_response = Micro::Core::Message.new(
            body: (ex.message || "Unknown error").to_slice,
            type: Micro::Core::MessageType::Error,
            headers: {"Error" => ex.class.name},
            id: UUID.random.to_s
          )

          begin
            socket.send(error_response)
          rescue
            # Ignore send errors
          end
        end
      end
    ensure
      # Only close the socket if we didn't hand it off to a stream handler
      socket.close unless stream_handled
    end

    private def handle_request(socket : WebSocketConnection, message : Micro::Core::Message)
      service = message.headers["Service"]? || message.target || ""
      method = message.headers["Method"]? || message.endpoint || ""
      content_type = message.headers["Content-Type"]? || "application/json"

      # Create transport request
      request = Micro::Core::TransportRequest.new(
        service: service,
        method: method,
        body: message.body,
        content_type: content_type,
        headers: message.headers
      )

      # Find handler
      handler = @handlers[method]? || @handlers["*"]?

      if handler
        # Call handler
        response = handler.call(request)

        # Send response
        resp_headers = response.headers.dup
        resp_headers["Status"] = response.status.to_s
        resp_headers["Content-Type"] = response.content_type

        response_msg = Micro::Core::Message.new(
          body: response.body,
          type: response.error? ? Micro::Core::MessageType::Error : Micro::Core::MessageType::Response,
          headers: resp_headers,
          id: message.id,
          reply_to: message.id
        )

        socket.send(response_msg)
      else
        # Send 404 response
        error_msg = Micro::Core::Message.new(
          body: "Handler not found".to_slice,
          type: Micro::Core::MessageType::Error,
          headers: {"Status" => "404"},
          id: message.id,
          reply_to: message.id
        )

        socket.send(error_msg)
      end
    end

    private def handle_stream_request(socket : WebSocketConnection, message : Micro::Core::Message)
      method = message.headers["Method"]? || message.endpoint || ""
      stream_id = message.headers["stream-id"]? || UUID.random.to_s

      puts "[Server] Handling stream request for method: #{method}, stream-id: #{stream_id}"

      # Find stream handler
      handler = @stream_handlers[method]?

      if handler
        # Create stream with the client's stream ID
        stream_headers = message.headers.dup
        stream_headers["stream-id"] = stream_id
        stream = WebSocketStream.new(socket, stream_headers)
        stream.id = stream_id # Use the client's stream ID

        # Create transport request for context
        request = Micro::Core::TransportRequest.new(
          service: message.headers["Service"]? || "",
          method: method,
          body: message.body,
          headers: message.headers
        )

        # Handle stream in separate fiber
        track_fiber("websocket-stream-handler-#{stream_id}") do
          begin
            handler.handle(stream, request)
          rescue ex
            handler.on_error(stream, ex)
          ensure
            handler.on_close(stream)
            stream.close unless stream.closed?
          end
        end
      else
        # Send error
        error_msg = Micro::Core::Message.new(
          body: "Stream handler not found".to_slice,
          type: Micro::Core::MessageType::Error,
          headers: {
            "Status"         => "404",
            "stream-id"      => stream_id,
            "stream-control" => "error",
            "stream-error"   => "Handler not found for method: #{method}",
          },
          id: message.id,
          reply_to: message.id
        )

        socket.send(error_msg)
      end
    end
  end
end
