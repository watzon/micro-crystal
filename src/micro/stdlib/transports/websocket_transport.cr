require "http/web_socket"
require "../../core/transport"
require "../../core/closable_resource"
require "../../core/fiber_tracker"
require "../tls_config"

module Micro::Stdlib::Transports
  # WebSocket transport implementation for real-time bidirectional communication
  class WebSocketTransport < Micro::Core::Transport
    def start : Nil
      @started = true
    end

    def stop : Nil
      @started = false
    end

    def listen(address : String) : Micro::Core::Listener
      WebSocketListener.new(address)
    end

    def dial(address : String, opts : Micro::Core::DialOptions? = nil) : Micro::Core::Socket
      WebSocketConnection.dial(address, opts || Micro::Core::DialOptions.new)
    end

    def address : String
      options.address
    end

    def protocol : String
      "websocket"
    end
  end

  # WebSocket implementation of Socket for bidirectional communication
  class WebSocketConnection < Micro::Core::Socket
    include Micro::Core::ClosableResource
    include Micro::Core::FiberTracker

    Log = ::Log.for("micro.transports.websocket")

    getter local_address : String
    getter remote_address : String

    @ws : HTTP::WebSocket
    @receive_channel : Channel(Micro::Core::Message)
    @message_fiber : Fiber?

    def initialize(@ws : HTTP::WebSocket, @local_address : String, @remote_address : String)
      @receive_channel = Channel(Micro::Core::Message).new(32)

      # Set up WebSocket event handlers
      setup_websocket_handlers

      # Start background fiber to handle WebSocket events
      @message_fiber = track_fiber("websocket-handler-#{object_id}") do
        handle_websocket_events
      end
    end

    private def setup_websocket_handlers
      @ws.on_message do |message|
        next if closed?

        begin
          msg = decode_message(message)
          @receive_channel.send(msg) unless closed?
        rescue ex
          Log.error(exception: ex) { "Error decoding WebSocket message" }
        end
      end

      @ws.on_close do |code, reason|
        Log.debug { "WebSocket closed: code=#{code}, reason=#{reason}" }
        close
      end
    end

    private def handle_websocket_events
      Log.debug { "Starting WebSocket event handler" }

      # Run the WebSocket event loop
      # This will block until the WebSocket is closed
      @ws.run
    rescue ex : IO::Error
      Log.error(exception: ex) { "WebSocket I/O error: #{ex.message}" }
      close
    rescue ex : Exception
      Log.error(exception: ex) { "WebSocket event handler crashed: #{ex.class.name}" }
      close
    ensure
      Log.debug { "WebSocket event handler finished" }
    end

    def self.dial(address : String, opts : Micro::Core::DialOptions) : WebSocketConnection
      uri = URI.parse(normalize_ws_address(address))

      # Create WebSocket client
      headers = HTTP::Headers.new
      opts.metadata.each { |k, v| headers[k] = v }

      # For client connections, we need to specify the host, path, and port separately
      host = uri.host || "localhost"
      path = uri.path.presence || "/"
      port = uri.port || (uri.scheme == "wss" ? 443 : 80)

      # Configure TLS for wss:// connections
      tls_context : HTTP::Client::TLSContext = if uri.scheme == "wss"
        if opts.tls_config? && (tls_config = opts.tls_config)
          # Use provided TLS configuration
          tls_config.to_openssl_context(:client).as(OpenSSL::SSL::Context::Client)
        else
          # Use default TLS configuration
          Micro::Stdlib::TLSRegistry.default_client.to_openssl_context(:client).as(OpenSSL::SSL::Context::Client)
        end
      else
        # No TLS for ws://
        nil
      end

      ws = HTTP::WebSocket.new(host, path, port, tls: tls_context, headers: headers)

      local_addr = "#{Socket::IPAddress::LOOPBACK}:0"
      remote_addr = "#{uri.host}:#{uri.port || (uri.scheme == "wss" ? 443 : 80)}"

      new(ws, local_addr, remote_addr)
    end

    def send(message : Micro::Core::Message) : Nil
      check_closed!

      # Encode message as JSON with type prefix
      data = encode_message(message)
      @ws.send(data)
    rescue ex : IO::Error
      close
      raise Micro::Core::TransportError.new("Failed to send message: #{ex.message}", Micro::Core::ErrorCode::ConnectionReset)
    end

    def receive : Micro::Core::Message
      check_closed!

      @receive_channel.receive
    rescue Channel::ClosedError
      close
      raise Micro::Core::TransportError.new("Socket closed", Micro::Core::ErrorCode::ConnectionReset)
    end

    def receive(timeout : Time::Span) : Micro::Core::Message?
      check_closed!

      select
      when msg = @receive_channel.receive
        msg
      when timeout(timeout)
        nil
      end
    rescue Channel::ClosedError
      close
      raise Micro::Core::TransportError.new("Socket closed", Micro::Core::ErrorCode::ConnectionReset)
    end

    # Implement the perform_close method required by ClosableResource
    protected def perform_close : Nil
      Log.debug { "Closing WebSocket socket" }

      # Shutdown background fiber first
      shutdown_fibers(5.seconds)

      # Close WebSocket connection
      begin
        @ws.close
      rescue ex : Exception
        Log.debug(exception: ex) { "Failed to close WebSocket connection" }
      end

      # Close receive channel
      begin
        @receive_channel.close
      rescue ex : Exception
        Log.debug(exception: ex) { "Failed to close receive channel" }
      end

      Log.debug { "WebSocket socket closed" }
    end

    def read_timeout=(timeout : Time::Span) : Nil
      # WebSocket doesn't support per-socket timeouts directly
      # Timeouts are handled in receive method
    end

    def write_timeout=(timeout : Time::Span) : Nil
      # WebSocket doesn't support per-socket timeouts directly
    end

    # Encodes a transport message to JSON string for WebSocket transmission.
    # Converts headers to hash format and base64-encodes the body.
    private def encode_message(message : Micro::Core::Message) : String
      # Convert headers to hash for JSON serialization
      headers_hash = {} of String => String
      message.headers.each do |key, values|
        headers_hash[key] = values.join(", ")
      end

      {
        "id"       => message.id,
        "type"     => message.type.to_s.downcase,
        "headers"  => headers_hash,
        "body"     => Base64.encode(message.body),
        "target"   => message.target,
        "endpoint" => message.endpoint,
        "reply_to" => message.reply_to,
      }.to_json
    end

    private def decode_message(data : String) : Micro::Core::Message
      json = JSON.parse(data)

      type = case json["type"].as_s
             when "request"  then Micro::Core::MessageType::Request
             when "response" then Micro::Core::MessageType::Response
             when "event"    then Micro::Core::MessageType::Event
             when "error"    then Micro::Core::MessageType::Error
             else
               Micro::Core::MessageType::Event
             end

      headers = json["headers"]?.try(&.as_h?) || {} of String => JSON::Any
      headers_str = headers.transform_values(&.to_s)

      # Convert to HTTP::Headers
      http_headers = HTTP::Headers.new
      headers_str.each do |key, value|
        http_headers[key] = value
      end

      Micro::Core::Message.new(
        body: Base64.decode(json["body"].as_s),
        type: type,
        headers: http_headers,
        id: json["id"].as_s,
        target: json["target"]?.try(&.as_s?),
        endpoint: json["endpoint"]?.try(&.as_s?),
        reply_to: json["reply_to"]?.try(&.as_s?)
      )
    end

    private def self.normalize_ws_address(address : String) : String
      # Ensure address has ws:// or wss:// scheme
      if address.starts_with?("ws://") || address.starts_with?("wss://")
        address
      elsif address.starts_with?("http://")
        address.sub("http://", "ws://")
      elsif address.starts_with?("https://")
        address.sub("https://", "wss://")
      else
        "ws://#{address}"
      end
    end
  end

  # WebSocket listener for accepting connections
  class WebSocketListener < Micro::Core::Listener
    include Micro::Core::ClosableResource
    include Micro::Core::FiberTracker

    Log = ::Log.for("micro.transports.websocket")

    getter address : String

    @server : HTTP::Server
    @accept_channel : Channel(WebSocketConnection)
    @server_fiber : Fiber?

    def initialize(@address : String)
      host, port_str = parse_address(@address)
      port = port_str.to_i

      @accept_channel = Channel(WebSocketConnection).new(32)

      # Create WebSocket handler
      ws_handler = HTTP::WebSocketHandler.new do |ws, context|
        remote_addr = context.request.remote_address.try(&.to_s) || "unknown"
        local_addr = @address

        socket = WebSocketConnection.new(ws, local_addr, remote_addr)

        # Send socket to accept channel unless closed
        unless closed?
          begin
            @accept_channel.send(socket)
          rescue Channel::ClosedError
            socket.close
            next
          end
        end

        # Keep the handler alive while the socket is active
        # This is required because HTTP::WebSocketHandler expects
        # the block to remain active for the lifetime of the connection
        while !socket.closed? && !closed?
          sleep 100.milliseconds
        end
      ensure
        socket.close if socket && !socket.closed?
      end

      # Create HTTP server with the WebSocket handler
      @server = HTTP::Server.new([ws_handler])
      @server.bind_tcp(host, port)
    end

    # Start listening for connections
    def start : Nil
      @server_fiber = track_fiber("websocket-listener-#{object_id}") do
        @server.listen unless closed?
      rescue ex
        Log.error(exception: ex) { "WebSocket listener error" }
        close
      end
    end

    def accept : Micro::Core::Socket
      check_closed!

      @accept_channel.receive
    rescue Channel::ClosedError
      close
      raise Micro::Core::TransportError.new("Listener closed", Micro::Core::ErrorCode::ConnectionReset)
    end

    def accept(timeout : Time::Span) : Micro::Core::Socket?
      check_closed!

      select
      when socket = @accept_channel.receive
        socket
      when timeout(timeout)
        nil
      end
    rescue Channel::ClosedError
      close
      raise Micro::Core::TransportError.new("Listener closed", Micro::Core::ErrorCode::ConnectionReset)
    end

    # Implement the perform_close method required by ClosableResource
    protected def perform_close : Nil
      Log.debug { "Closing WebSocket listener" }

      # Close the server first to stop accepting new connections
      begin
        @server.close
      rescue ex : Exception
        Log.debug(exception: ex) { "Failed to close WebSocket server" }
      end

      # Shutdown server fiber
      shutdown_fibers(5.seconds)

      # Close accept channel
      begin
        @accept_channel.close
      rescue ex : Exception
        Log.debug(exception: ex) { "Failed to close accept channel" }
      end

      Log.debug { "WebSocket listener closed" }
    end

    private def parse_address(address : String) : {String, String}
      if address.includes?(":")
        parts = address.split(":", 2)
        {parts[0], parts[1]}
      else
        {"0.0.0.0", address}
      end
    end
  end
end
