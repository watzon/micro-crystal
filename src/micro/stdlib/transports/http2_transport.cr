require "http/server"
require "http/client"
require "socket"
require "openssl"
require "uuid"
require "http2"
require "http2/connection"
require "http2/stream"
require "http2/frame"
require "../../core/transport"
require "../../core/closable_resource"
require "../../core/fiber_tracker"
require "../tls_config"

module Micro::Stdlib::Transports
  # HTTP/2 Transport implementation with multiplexing support
  class HTTP2Transport < Micro::Core::Transport
    def protocol : String
      "http2"
    end

    def start : Nil
      @started = true
    end

    def stop : Nil
      @started = false
    end

    def address : String
      options.address
    end

    def listen(address : String) : Micro::Core::Listener
      HTTP2Listener.new(address, options)
    end

    def dial(address : String, opts : Micro::Core::DialOptions? = nil) : Micro::Core::Socket
      HTTP2ClientConnection.new(address, opts || Micro::Core::DialOptions.new)
    end
  end

  # HTTP/2 Client Socket - implements client side of HTTP/2 transport
  class HTTP2ClientConnection < Micro::Core::Socket
    include Micro::Core::ClosableResource
    include Micro::Core::FiberTracker

    @uri : URI
    @opts : Micro::Core::DialOptions
    @local_address : String
    @remote_address : String
    @read_timeout : Time::Span = 30.seconds
    @write_timeout : Time::Span = 30.seconds
    @socket : IO?
    @connection : HTTP2::Connection?
    @stream : HTTP2::Stream?
    @receive_channel = Channel(Micro::Core::Message).new
    @send_channel = Channel(Micro::Core::Message).new
    @connection_fiber : Fiber?

    def initialize(address : String, @opts : Micro::Core::DialOptions)
      # Ensure we have a proper URL
      url = if address.starts_with?("http://") || address.starts_with?("https://")
              address
            else
              # Default to https for HTTP/2
              "https://#{address}"
            end

      @uri = URI.parse(url)
      default_port = @uri.scheme == "https" ? 443 : 80
      @remote_address = "#{@uri.host}:#{@uri.port || default_port}"
      @local_address = "127.0.0.1:0" # Client doesn't have a real local address until connected

      connect
    end

    private def connect
      host = @uri.host || raise Micro::Core::TransportError.new(
        "URI host is required for HTTP/2 connection",
        Micro::Core::ErrorCode::InvalidMessage
      )
      port = @uri.port || (@uri.scheme == "https" ? 443 : 80)

      # Create TCP socket
      tcp_socket = TCPSocket.new(host, port)
      tcp_socket.read_timeout = @read_timeout
      tcp_socket.write_timeout = @write_timeout

      @socket = if @uri.scheme == "https"
                  # Get TLS configuration from dial options or use default
                  tls_config = if @opts.tls_config? && (boxed_config = @opts.tls_config)
                                 # Unbox the TLS configuration
                                 boxed_config.as(Micro::Stdlib::TLSConfig)
                               else
                                 Micro::Stdlib::TLSRegistry.default_client
                               end

                  # Create SSL context with proper configuration
                  ssl_context = tls_config.to_openssl_context(:client)

                  # Ensure we have a client context
                  ssl_socket = case ssl_context
                               when OpenSSL::SSL::Context::Client
                                 # ALPN negotiation for HTTP/2
                                 ssl_context.alpn_protocol = "h2"
                                 socket = OpenSSL::SSL::Socket::Client.new(tcp_socket, ssl_context, hostname: host)
                                 socket.sync_close = true
                                 socket
                               else
                                 raise Micro::Core::TransportError.new(
                                   "Expected client SSL context but got #{ssl_context.class}",
                                   Micro::Core::ErrorCode::InvalidMessage
                                 )
                               end

                  ssl_socket
                else
                  tcp_socket
                end

      # Update local address after connection
      if tcp = tcp_socket
        @local_address = "#{tcp.local_address}:#{tcp.local_address.port}"
      end

      # Create HTTP/2 connection
      socket = @socket || raise Micro::Core::TransportError.new(
        "Socket not initialized",
        Micro::Core::ErrorCode::Internal
      )
      @connection = HTTP2::Connection.new(socket, HTTP2::Connection::Type::CLIENT)

      # Send client preface and settings
      connection = @connection || raise Micro::Core::TransportError.new(
        "Connection not initialized",
        Micro::Core::ErrorCode::Internal
      )
      connection.write_client_preface
      connection.write_settings

      # Start connection handler
      @connection_fiber = track_fiber("http2-connection-#{object_id}") do
        handle_connection
      end
    end

    private def handle_connection
      connection = @connection || return

      # First receive server settings
      frame = connection.receive
      unless frame && frame.type == HTTP2::Frame::Type::SETTINGS
        raise Micro::Core::TransportError.new("Expected SETTINGS frame", Micro::Core::ErrorCode::InvalidMessage)
      end

      # Read frames in a loop
      loop do
        break if closed?

        frame = connection.receive
        next unless frame

        case frame.type
        when HTTP2::Frame::Type::DATA
          handle_data_frame(frame)
        when HTTP2::Frame::Type::HEADERS
          handle_headers_frame(frame)
        when HTTP2::Frame::Type::GOAWAY
          # Connection is being closed
          break
        end
      end
    rescue HTTP2::Error
      # Connection closed or protocol error, this is expected
      close
    rescue ex : IO::Error
      # Socket closed, this is expected
      close
    rescue ex
      # Log unexpected errors
      Log.error(exception: ex) { "HTTP/2 connection error" }
      close
    ensure
      Log.debug { "HTTP/2 connection handler finished" }
    end

    private def handle_data_frame(frame : HTTP2::Frame)
      # Find the stream
      stream = frame.stream
      return unless stream

      # Data is already added to stream.data by the connection
      # Check if this is the end of the stream
      if frame.flags.includes?(HTTP2::Frame::Flags::END_STREAM)
        # Create message from accumulated data
        msg = stream_to_message(stream)
        @receive_channel.send(msg)
      end
    end

    private def handle_headers_frame(frame : HTTP2::Frame)
      # Headers are already decoded and stored in the stream
      # We'll create the message when we get END_STREAM
    end

    def local_address : String
      @local_address
    end

    def remote_address : String
      @remote_address
    end

    def send(message : Micro::Core::Message) : Nil
      check_closed!

      # Create a new stream for this request
      connection = @connection || raise Micro::Core::TransportError.new(
        "Connection not established",
        Micro::Core::ErrorCode::NotConnected
      )
      stream = connection.streams.create

      # Store stream for response correlation
      @stream = stream

      # Convert message to HTTP/2 headers
      headers = HTTP::Headers{
        ":method"        => "POST",
        ":path"          => message.endpoint || "/",
        ":scheme"        => @uri.scheme || "https",
        ":authority"     => "#{@uri.host}:#{@uri.port || 443}",
        "content-type"   => message.headers["content-type"]? || "application/octet-stream",
        "x-message-id"   => message.id,
        "x-message-type" => message.type.to_s,
      }

      # Add custom headers
      message.headers.each do |key, value|
        headers[key] = value unless key.starts_with?(":")
      end

      # Send headers with END_HEADERS flag
      stream.send_headers(headers, HTTP2::Frame::Flags::END_HEADERS)

      # Send data if present
      if message.body.empty?
        # Send empty data frame with END_STREAM
        stream.send_data(Bytes.empty, HTTP2::Frame::Flags::END_STREAM)
      else
        # Send data with END_STREAM
        stream.send_data(message.body, HTTP2::Frame::Flags::END_STREAM)
      end
    end

    def receive : Micro::Core::Message
      check_closed!

      result = receive(nil)
      raise Micro::Core::TransportError.new("No message received", Micro::Core::ErrorCode::Timeout) unless result
      result
    end

    def receive(timeout : Time::Span?) : Micro::Core::Message?
      check_closed!

      if timeout
        select
        when msg = @receive_channel.receive
          msg
        when timeout(timeout)
          nil
        end
      else
        @receive_channel.receive
      end
    rescue Channel::ClosedError
      close
      raise Micro::Core::TransportError.new("Socket closed", Micro::Core::ErrorCode::ConnectionReset)
    end

    # Implement the perform_close method required by ClosableResource
    protected def perform_close : Nil
      Log.debug { "Closing HTTP/2 client socket" }

      # Shutdown connection fiber
      shutdown_fibers(5.seconds)

      # Send GOAWAY frame
      @connection.try(&.close) rescue ex : Exception
      Log.debug(exception: ex) { "Failed to close HTTP/2 connection" }

      # Close underlying socket
      @socket.try(&.close) rescue ex : Exception
      Log.debug(exception: ex) { "Failed to close socket" }

      # Close channels
      @receive_channel.close rescue ex : Exception
      Log.debug(exception: ex) { "Failed to close receive channel" }
      @send_channel.close rescue ex : Exception
      Log.debug(exception: ex) { "Failed to close send channel" }

      Log.debug { "HTTP/2 client socket closed" }
    end

    def read_timeout=(timeout : Time::Span) : Nil
      @read_timeout = timeout
      @socket.try { |s| s.read_timeout = timeout if s.responds_to?(:read_timeout=) }
    end

    def write_timeout=(timeout : Time::Span) : Nil
      @write_timeout = timeout
      @socket.try { |s| s.write_timeout = timeout if s.responds_to?(:write_timeout=) }
    end

    private def stream_to_message(stream : HTTP2::Stream) : Micro::Core::Message
      # Get all data from stream
      data_io = stream.data

      # Read all available data
      data = if data_io.size > 0
               buffer = Bytes.new(data_io.size)
               data_io.read_fully(buffer)
               buffer
             else
               Bytes.empty
             end

      # Extract headers
      headers = stream.headers

      # Determine message type from status
      msg_type = case headers[":status"]?
                 when "200"
                   Micro::Core::MessageType::Response
                 when nil
                   Micro::Core::MessageType::Request
                 else
                   Micro::Core::MessageType::Error
                 end

      # Build message
      msg_headers = HTTP::Headers.new
      headers.each do |key, values|
        next if key.starts_with?(":")
        msg_headers[key] = values.join(", ")
      end

      Micro::Core::Message.new(
        body: data,
        type: msg_type,
        headers: msg_headers,
        id: headers["x-message-id"]? || UUID.random.to_s,
        endpoint: headers[":path"]?
      )
    end
  end

  # HTTP/2 Server Socket - implements server side of HTTP/2 transport
  class HTTP2ServerConnection < Micro::Core::Socket
    include Micro::Core::ClosableResource
    include Micro::Core::FiberTracker

    @socket : IO
    @connection : HTTP2::Connection
    @local_address : String
    @remote_address : String
    @read_timeout : Time::Span = 30.seconds
    @write_timeout : Time::Span = 30.seconds
    @receive_channel = Channel(Micro::Core::Message).new
    @stream_map = {} of Int32 => HTTP2::Stream
    @connection_fiber : Fiber?

    def initialize(@socket : IO, @local_address : String, @remote_address : String)
      # Create HTTP/2 server connection
      @connection = HTTP2::Connection.new(@socket, HTTP2::Connection::Type::SERVER)

      # Write server settings
      @connection.write_settings

      # Start handling connection
      @connection_fiber = track_fiber("http2-server-connection-#{object_id}") do
        handle_connection
      end
    end

    private def handle_connection
      # Read frames
      loop do
        break if closed?

        frame = @connection.receive
        next unless frame

        case frame.type
        when HTTP2::Frame::Type::HEADERS
          handle_headers_frame(frame)
        when HTTP2::Frame::Type::DATA
          handle_data_frame(frame)
        when HTTP2::Frame::Type::GOAWAY
          break
        end
      rescue ex
        break
      end
    end

    private def handle_headers_frame(frame : HTTP2::Frame)
      # Headers are already processed by the connection and stored in the stream
      stream = frame.stream
      return unless stream

      # Store stream for later response
      @stream_map[stream.id] = stream
    end

    private def handle_data_frame(frame : HTTP2::Frame)
      stream = frame.stream
      return unless stream

      # Check if this is the end of the stream
      if frame.flags.includes?(HTTP2::Frame::Flags::END_STREAM)
        # Create message from stream
        msg = stream_to_message(stream)

        # Store stream ID for response correlation
        msg.headers["__stream_id"] = stream.id.to_s

        @receive_channel.send(msg)
      end
    end

    private def stream_to_message(stream : HTTP2::Stream) : Micro::Core::Message
      # Get all data from stream
      data_io = stream.data

      # Read all available data
      data = if data_io.size > 0
               buffer = Bytes.new(data_io.size)
               data_io.read_fully(buffer)
               buffer
             else
               Bytes.empty
             end

      # Extract headers
      headers = stream.headers

      # Build message
      msg_headers = HTTP::Headers.new
      headers.each do |key, values|
        next if key.starts_with?(":")
        msg_headers[key] = values.join(", ")
      end

      Micro::Core::Message.new(
        body: data,
        type: Micro::Core::MessageType::Request,
        headers: msg_headers,
        id: headers["x-message-id"]? || UUID.random.to_s,
        endpoint: headers[":path"]?
      )
    end

    def local_address : String
      @local_address
    end

    def remote_address : String
      @remote_address
    end

    def send(message : Micro::Core::Message) : Nil
      check_closed!

      # Get stream ID from message
      stream_id = message.headers["__stream_id"]?.try(&.to_i)
      return unless stream_id

      # Find the stream
      stream = @stream_map[stream_id]?
      return unless stream

      # Send response headers
      headers = HTTP::Headers{
        ":status"        => message.headers["status"]? || "200",
        "content-type"   => message.headers["content-type"]? || "application/octet-stream",
        "x-message-id"   => message.id,
        "x-message-type" => message.type.to_s,
      }

      # Add custom headers
      message.headers.each do |key, value|
        headers[key] = value unless key.starts_with?(":") || key == "__stream_id"
      end

      stream.send_headers(headers, HTTP2::Frame::Flags::END_HEADERS)

      # Send data with END_STREAM
      if message.body.empty?
        stream.send_data(Bytes.empty, HTTP2::Frame::Flags::END_STREAM)
      else
        stream.send_data(message.body, HTTP2::Frame::Flags::END_STREAM)
      end
    end

    def receive : Micro::Core::Message
      check_closed!

      @receive_channel.receive
    rescue Channel::ClosedError
      close
      raise Micro::Core::TransportError.new("Socket closed", Micro::Core::ErrorCode::ConnectionReset)
    end

    def receive(timeout : Time::Span?) : Micro::Core::Message?
      check_closed!

      if timeout
        select
        when msg = @receive_channel.receive
          msg
        when timeout(timeout)
          nil
        end
      else
        @receive_channel.receive?
      end
    rescue Channel::ClosedError
      close
      raise Micro::Core::TransportError.new("Socket closed", Micro::Core::ErrorCode::ConnectionReset)
    end

    # Implement the perform_close method required by ClosableResource
    protected def perform_close : Nil
      Log.debug { "Closing HTTP/2 server socket" }

      # Shutdown connection fiber
      shutdown_fibers(5.seconds)

      # Close connection and socket
      @connection.close rescue ex : Exception
      Log.debug(exception: ex) { "Failed to close HTTP/2 connection" }
      @socket.close rescue ex : Exception
      Log.debug(exception: ex) { "Failed to close socket" }

      # Close receive channel
      @receive_channel.close rescue ex : Exception
      Log.debug(exception: ex) { "Failed to close receive channel" }

      Log.debug { "HTTP/2 server socket closed" }
    end

    def read_timeout=(timeout : Time::Span) : Nil
      @read_timeout = timeout
      @socket.read_timeout = timeout if @socket.responds_to?(:read_timeout=)
    end

    def write_timeout=(timeout : Time::Span) : Nil
      @write_timeout = timeout
      @socket.write_timeout = timeout if @socket.responds_to?(:write_timeout=)
    end
  end

  # HTTP/2 Listener - accepts incoming HTTP/2 connections
  class HTTP2Listener < Micro::Core::Listener
    include Micro::Core::ClosableResource
    include Micro::Core::FiberTracker

    @server : HTTP::Server?
    @server_fiber : Fiber?
    @address : String
    @accept_channel = Channel(Micro::Core::Socket).new
    @transport_options : Micro::Core::Transport::Options

    def initialize(@address : String, @transport_options : Micro::Core::Transport::Options)
      setup_server unless closed?
    end

    private def setup_server
      # Parse address
      host, port = parse_address(@address)

      # Create HTTP server with HTTP/2 support
      @server = HTTP::Server.new do |context|
        # This handler won't be used for HTTP/2
        context.response.status_code = 505
        context.response.print "HTTP/2 Required"
      end

      # Bind to address
      server = @server || raise Micro::Core::TransportError.new(
        "Server not initialized",
        Micro::Core::ErrorCode::Internal
      )

      if @transport_options.secure
        # Get TLS configuration from transport options or use default
        tls_config = if @transport_options.tls_config? && (boxed_config = @transport_options.tls_config)
                       # Unbox the TLS configuration
                       boxed_config.as(Micro::Stdlib::TLSConfig)
                     else
                       # Secure mode enabled but no config provided - error
                       raise Micro::Core::TransportError.new(
                         "TLS enabled but no TLS configuration provided",
                         Micro::Core::ErrorCode::InvalidMessage
                       )
                     end

        # Create SSL context with proper configuration
        ssl_context = tls_config.to_openssl_context(:server)

        # Ensure we have a server context
        case ssl_context
        when OpenSSL::SSL::Context::Server
          # ALPN negotiation for HTTP/2
          ssl_context.alpn_protocol = "h2"
          server.bind_tls(host, port, ssl_context)
        else
          raise Micro::Core::TransportError.new(
            "Failed to create server SSL context",
            Micro::Core::ErrorCode::InvalidMessage
          )
        end
      else
        server.bind_tcp(host, port)
      end

      # Start server in background
      @server_fiber = track_fiber("http2-listener-#{object_id}") do
        server.listen unless closed?
      rescue ex
        Log.error(exception: ex) { "HTTP/2 server error" }
        close
      end

      # Update actual address after binding
      if server_address = server.addresses.first?
        case server_address
        when Socket::IPAddress
          @address = "#{server_address.address}:#{server_address.port}"
        when Socket::UNIXAddress
          @address = server_address.path
        else
          # Keep original address
        end
      end
    end

    private def parse_address(addr : String) : {String, Int32}
      if addr.includes?(":")
        parts = addr.split(":", 2)
        {parts[0], parts[1].to_i}
      else
        {"0.0.0.0", addr.to_i}
      end
    end

    def address : String
      @address
    end

    def accept : Micro::Core::Socket
      check_closed!

      @accept_channel.receive
    rescue Channel::ClosedError
      close
      raise Micro::Core::TransportError.new("Listener is closed", Micro::Core::ErrorCode::ConnectionReset)
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
      raise Micro::Core::TransportError.new("Listener is closed", Micro::Core::ErrorCode::ConnectionReset)
    end

    # Implement the perform_close method required by ClosableResource
    protected def perform_close : Nil
      Log.debug { "Closing HTTP/2 listener" }

      # Close the server first to stop accepting new connections
      @server.try(&.close) rescue nil

      # Shutdown server fiber
      shutdown_fibers(5.seconds)

      # Close the accept channel
      @accept_channel.close rescue nil

      Log.debug { "HTTP/2 listener closed" }
    end
  end

  # HTTP/2 Stream implementation for bidirectional streaming
  class HTTP2Stream < Micro::Core::Stream
    include Micro::Core::ClosableResource
    include Micro::Core::FiberTracker

    @stream : HTTP2::Stream
    @connection : HTTP2::Connection
    @send_closed = false
    @receive_channel = Channel(Bytes).new
    @data_buffer = IO::Memory.new
    @monitor_fiber : Fiber?

    def initialize(@stream : HTTP2::Stream, @connection : HTTP2::Connection)
      setup_handlers
    end

    private def setup_handlers
      # Monitor the stream's data buffer for incoming data
      @monitor_fiber = track_fiber("http2-stream-monitor-#{object_id}") do
        monitor_stream_data
      end
    end

    private def monitor_stream_data
      # Since HTTP2::Stream accumulates data in stream.data,
      # we need to monitor it for changes
      loop do
        break if closed?

        # Check if there's data available
        data_io = @stream.data
        if data_io.size > @data_buffer.size
          # Read new data
          new_data_size = data_io.size - @data_buffer.size
          new_data = Bytes.new(new_data_size)
          data_io.pos = @data_buffer.size
          data_io.read(new_data)

          @data_buffer.write(new_data)
          @receive_channel.send(new_data) unless @closed
        end

        # Check stream state
        if @stream.state == HTTP2::Stream::State::CLOSED
          @closed = true
          @receive_channel.close
          break
        end

        sleep 0.01.seconds # Small delay to avoid busy waiting


      rescue
        break
      end
    end

    def send(body : Bytes) : Nil
      raise Micro::Core::TransportError.new("Stream is closed", Micro::Core::ErrorCode::ConnectionReset) if @send_closed

      @stream.send_data(body)
    end

    def receive : Bytes
      @receive_channel.receive
    end

    def receive(timeout : Time::Span) : Bytes?
      select
      when data = @receive_channel.receive
        data
      when timeout(timeout)
        nil
      end
    end

    # Implement the perform_close method required by ClosableResource
    protected def perform_close : Nil
      Log.debug { "Closing HTTP/2 stream" }

      # Close send side first
      close_send

      # Shutdown monitor fiber
      shutdown_fibers(5.seconds)

      # Send RST_STREAM frame
      @stream.send_rst_stream(HTTP2::Error::Code::NO_ERROR) rescue nil

      # Close receive channel
      @receive_channel.close rescue nil

      Log.debug { "HTTP/2 stream closed" }
    end

    def close_send : Nil
      return if @send_closed
      @send_closed = true
      @stream.send_data(Bytes.empty, HTTP2::Frame::Flags::END_STREAM)
    end

    def send_closed? : Bool
      @send_closed
    end
  end
end
