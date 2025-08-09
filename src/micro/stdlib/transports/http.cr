require "http/server"
require "http/client"
require "uuid"
require "../../core/transport"
require "../../core/closable_resource"
require "../../core/fiber_tracker"
require "../../core/message_encoder"
require "../../core/errors"
require "../tls_config"

module Micro::Stdlib::Transports
  Log = ::Log.for("micro.transports.http")

  # HTTP Transport implementation
  # Note: HTTP is a request-response protocol, so bidirectional streaming
  # is simulated using long-polling or multiple requests
  class HTTPTransport < Micro::Core::Transport
    def protocol : String
      "http"
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
      HTTPListener.new(address)
    end

    def dial(address : String, opts : Micro::Core::DialOptions? = nil) : Micro::Core::Socket
      HTTPClientConnection.new(address, opts || Micro::Core::DialOptions.new)
    end
  end

  # HTTP Client Connection - implements client side of HTTP transport
  class HTTPClientConnection < Micro::Core::Socket
    include Micro::Core::ClosableResource
    include Micro::Core::FiberTracker

    @client : HTTP::Client?
    @uri : URI
    @opts : Micro::Core::DialOptions
    @local_address : String
    @remote_address : String
    @read_timeout : Time::Span = 30.seconds
    @write_timeout : Time::Span = 30.seconds

    def initialize(address : String, @opts : Micro::Core::DialOptions)
      # Ensure we have a proper URL
      url = if address.starts_with?("http://") || address.starts_with?("https://")
              address
            else
              "http://#{address}"
            end

      @uri = URI.parse(url)
      default_port = @uri.scheme == "https" ? 443 : 80
      @remote_address = "#{@uri.host}:#{@uri.port || default_port}"
      @local_address = "127.0.0.1:0" # Client doesn't have a real local address
    end

    # Lazy initialization of HTTP client to avoid timing issues with WebMock
    private def client : HTTP::Client
      @client ||= begin
        # Configure TLS if using HTTPS
        if @uri.scheme == "https"
          # Get TLS configuration
          tls_config = if @opts.tls_config? && (boxed_config = @opts.tls_config)
                         # Unbox the TLS configuration
                         boxed_config.as(Micro::Stdlib::TLSConfig)
                       else
                         # Use default TLS configuration for HTTPS
                         Micro::Stdlib::TLSRegistry.default_client
                       end

          # Create client context explicitly
          client_context = tls_config.to_openssl_context(:client).as(OpenSSL::SSL::Context::Client)
          c = HTTP::Client.new(@uri, tls: client_context)
        else
          c = HTTP::Client.new(@uri)
        end
        c.read_timeout = @opts.timeout
        c.connect_timeout = @opts.timeout

        # Add metadata as default headers
        @opts.metadata.each do |key, value|
          c.before_request do |request|
            request.headers[key] = value
          end
        end

        c
      end
    end

    def local_address : String
      @local_address
    end

    def remote_address : String
      @remote_address
    end

    def send(message : Micro::Core::Message) : Nil
      check_closed!

      # For HTTP client, send means making a request
      # We don't actually send here, but queue it for the next receive
      # This is because HTTP is request-response
      @pending_message = message
    end

    def receive : Micro::Core::Message
      result = receive(nil)
      raise Micro::Core::TransportError.new("No message received", Micro::Core::ErrorCode::Timeout) unless result
      result
    end

    def receive(timeout : Time::Span?) : Micro::Core::Message?
      check_closed!

      # If no pending message, we can't receive
      pending = @pending_message
      return nil unless pending

      @pending_message = nil

      # Make the HTTP request
      headers = HTTP::Headers.new
      pending.headers.each { |k, v| headers[k] = v }
      headers["X-Message-Id"] = pending.id
      headers["X-Message-Type"] = pending.type.to_s
      headers["Content-Type"] ||= "application/octet-stream"

      if target = pending.target
        headers["X-Target-Service"] = target
      end

      if endpoint = pending.endpoint
        headers["X-Target-Endpoint"] = endpoint
      end

      path = pending.endpoint || "/"

      begin
        response = if timeout
                     # Create a fiber for timeout
                     channel = Channel(HTTP::Client::Response?).new

                     track_fiber("http-client-request-#{object_id}") do
                       begin
                         channel.send(client.post(path, headers: headers, body: pending.body))
                       rescue ex
                         Log.debug(exception: ex) { "HTTP request failed" }
                         channel.send(nil)
                       ensure
                         # Channel will be closed after select completes
                       end
                     end

                     begin
                       select
                       when resp = channel.receive
                         resp
                       when timeout(timeout)
                         nil
                       end
                     ensure
                       begin
                         channel.close
                       rescue ex : Exception
                         Log.debug(exception: ex) { "Failed to close channel" }
                       end
                     end
                   else
                     client.post(path, headers: headers, body: pending.body)
                   end

        return nil unless response

        # Convert response to message
        # Create headers with status code
        response_headers = HTTP::Headers.new
        response.headers.each do |key, values|
          values.each { |value| response_headers.add(key, value) }
        end
        response_headers["X-Status-Code"] = response.status_code.to_s

        Micro::Core::Message.new(
          body: Micro::Core::MessageEncoder.to_bytes(response.body),
          type: response.status_code >= 400 ? Micro::Core::MessageType::Error : Micro::Core::MessageType::Response,
          headers: response_headers,
          id: response.headers["X-Message-Id"]? || UUID.random.to_s
        )
      rescue ex : Socket::ConnectError
        raise Micro::Core::TransportError.new(
          "Connection failed: #{ex.message}",
          Micro::Core::ErrorCode::ConnectionRefused
        )
      rescue ex : IO::TimeoutError
        raise Micro::Core::TransportError.new(
          "Request timed out: #{ex.message}",
          Micro::Core::ErrorCode::Timeout
        )
      rescue ex : IO::Error
        raise Micro::Core::TransportError.new(
          "IO error: #{ex.message}",
          Micro::Core::ErrorCode::ConnectionReset
        )
      rescue ex
        # Convert any other error to TransportError for consistency
        raise Micro::Core::Errors.to_transport_error(ex, "HTTP request failed")
      end
    end

    # Implement the perform_close method required by ClosableResource
    protected def perform_close : Nil
      Log.debug { "Closing HTTP client socket" }
      @client.try(&.close)
      # Shutdown any tracked fibers for this connection
      shutdown_fibers(1.second)
    end

    def read_timeout=(timeout : Time::Span) : Nil
      @read_timeout = timeout
      @client.try(&.read_timeout=(timeout))
    end

    def write_timeout=(timeout : Time::Span) : Nil
      @write_timeout = timeout
      # HTTP::Client doesn't have a separate write timeout
    end

    @pending_message : Micro::Core::Message?
  end

  # HTTP Listener - accepts incoming HTTP connections
  class HTTPListener < Micro::Core::Listener
    include Micro::Core::ClosableResource
    include Micro::Core::FiberTracker

    @server : HTTP::Server
    @address : String
    @actual_address : String
    @connections = Channel(HTTPServerConnection).new(100)
    @server_fiber : Fiber?

    def initialize(address : String)
      @address = address

      # Parse address
      host, port = if address.includes?(":")
                     parts = address.split(":", 2)
                     {parts[0], parts[1].to_i}
                   else
                     {"0.0.0.0", address.to_i}
                   end

      @server = HTTP::Server.new do |context|
        handle_request(context)
      end

      # Bind and get actual address
      addr = @server.bind_tcp(host, port)
      @actual_address = "#{addr.address}:#{addr.port}"

      # Start server in background with non-blocking approach
      @server_fiber = track_fiber("http-listener-#{object_id}") do
        begin
          @server.listen unless closed?
        rescue ex : Socket::BindError
          Log.error(exception: ex) { "Failed to bind HTTP server" }
          raise ex
        rescue ex
          # Server was closed, this is expected during shutdown
          Log.debug { "HTTP server stopped: #{ex.message}" }
        ensure
          close unless closed?
        end
      end

      # Give the server a moment to start listening
      sleep 200.milliseconds
    end

    def address : String
      @actual_address
    end

    def accept : Micro::Core::Socket
      check_closed!
      @connections.receive
    rescue Channel::ClosedError
      close
      raise Micro::Core::TransportError.new("Listener is closed", Micro::Core::ErrorCode::ConnectionReset)
    end

    def accept(timeout : Time::Span) : Micro::Core::Socket?
      check_closed!

      select
      when connection = @connections.receive
        connection
      when timeout(timeout)
        nil
      end
    rescue Channel::ClosedError
      close
      raise Micro::Core::TransportError.new("Listener is closed", Micro::Core::ErrorCode::ConnectionReset)
    end

    # Implement the perform_close method required by ClosableResource
    protected def perform_close : Nil
      Log.debug { "Closing HTTP listener" }

      # Close the server first to stop accepting new connections
      begin
        @server.close
      rescue ex : Exception
        Log.debug(exception: ex) { "Failed to close HTTP server" }
      end

      # Close connections channel to unblock any waiting accepts
      begin
        @connections.close
      rescue ex : Exception
        Log.debug(exception: ex) { "Failed to close connections channel" }
      end

      # The HTTP::Server.listen method blocks even after close is called.
      # This is a known limitation in Crystal's HTTP server.
      # We don't wait for the fiber as it would hang indefinitely.

      Log.debug { "HTTP listener closed" }
    end

    # Handles incoming HTTP requests on the server side.
    # Creates a server socket for the request and queues it for processing.
    private def handle_request(context : HTTP::Server::Context)
      return if closed?

      socket : HTTPServerConnection? = nil

      begin
        # Create a server socket for this request/response pair
        socket = HTTPServerConnection.new(context, @actual_address)

        # Queue the connection unless closed
        if closed?
          context.response.status_code = 503
          context.response.print("Service unavailable")
          return
        else
          @connections.send(socket)
        end

        # Wait for the socket to be processed
        # This blocks the HTTP response until the handler processes it
        socket.wait_for_response
      rescue Channel::ClosedError
        # Listener was closed
        context.response.status_code = 503
        context.response.print("Service unavailable")
      rescue ex
        Log.error(exception: ex) { "Error handling request: #{ex.message}" }
        context.response.status_code = 500
        context.response.print("Internal server error")
      ensure
        # Ensure socket is closed if created
        socket.try(&.close) if socket && !socket.closed?
      end
    end
  end

  # HTTP Server Socket - represents a single HTTP request/response exchange
  class HTTPServerConnection < Micro::Core::Socket
    include Micro::Core::ClosableResource

    @context : HTTP::Server::Context
    @local_address : String
    @remote_address : String
    @read_timeout : Time::Span = 30.seconds
    @write_timeout : Time::Span = 30.seconds
    @request_message : Micro::Core::Message?
    @response_channel = Channel(Micro::Core::Message).new(1)

    def initialize(@context : HTTP::Server::Context, local_addr : String)
      @local_address = local_addr
      @remote_address = @context.request.remote_address.try(&.to_s) || "unknown"

      # Convert the HTTP request to a Message immediately
      body = @context.request.body.try { |b| Micro::Core::MessageEncoder.to_bytes(b.gets_to_end) } || Bytes.empty
      # Headers are already HTTP::Headers in context.request
      headers = @context.request.headers

      message_type = case @context.request.headers["X-Message-Type"]?
                     when "Response"
                       Micro::Core::MessageType::Response
                     when "Event"
                       Micro::Core::MessageType::Event
                     when "Error"
                       Micro::Core::MessageType::Error
                     else
                       Micro::Core::MessageType::Request
                     end

      @request_message = Micro::Core::Message.new(
        body: body,
        type: message_type,
        headers: headers,
        id: @context.request.headers["X-Message-Id"]? || UUID.random.to_s,
        target: @context.request.headers["X-Target-Service"]?,
        endpoint: @context.request.path,
        reply_to: @context.request.headers["X-Reply-To"]?
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

      # Queue the response
      @response_channel.send(message)
    rescue Channel::ClosedError
      raise Micro::Core::TransportError.new("Response channel closed", Micro::Core::ErrorCode::ConnectionReset)
    end

    def receive : Micro::Core::Message
      check_closed!

      # Return the request message (only once)
      if msg = @request_message
        @request_message = nil
        msg
      else
        raise Micro::Core::TransportError.new("No message available", Micro::Core::ErrorCode::InvalidMessage)
      end
    end

    def receive(timeout : Time::Span) : Micro::Core::Message?
      check_closed!

      # For server sockets, we already have the request
      @request_message
    end

    # Implement the perform_close method required by ClosableResource
    protected def perform_close : Nil
      Log.debug { "Closing HTTP server socket" }

      # Close response channel
      begin
        @response_channel.close
      rescue ex : Exception
        Log.debug(exception: ex) { "Failed to close response channel" }
      end

      # Clear request message
      @request_message = nil

      Log.debug { "HTTP server socket closed" }
    end

    def read_timeout=(timeout : Time::Span) : Nil
      @read_timeout = timeout
    end

    def write_timeout=(timeout : Time::Span) : Nil
      @write_timeout = timeout
    end

    # Wait for response to be sent
    def wait_for_response
      return if closed?

      begin
        message = @response_channel.receive

        # Write response
        message.headers.each { |k, v| @context.response.headers[k] = v }
        @context.response.headers["X-Message-Id"] = message.id
        @context.response.headers["X-Message-Type"] = message.type.to_s
        @context.response.content_type = message.headers["Content-Type"]? || "application/octet-stream"

        @context.response.status_code = if status_code = message.headers["X-Status-Code"]?
                                          status_code.to_i
                                        else
                                          case message.type
                                          when .error?
                                            500
                                          else
                                            200
                                          end
                                        end

        @context.response.write(message.body)
      rescue Channel::ClosedError
        # Socket was closed without response
        @context.response.status_code = 500
        @context.response.print("No response")
      rescue ex
        Log.error(exception: ex) { "Error sending response" }
        @context.response.status_code = 500
        @context.response.print("Internal server error")
      ensure
        # Always close the socket after handling the response
        close
      end
    end
  end
end
