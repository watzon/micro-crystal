require "../../core/transport"
require "./http2_transport"

module Micro::Stdlib::Transports
  # HTTP/2 Client implementation with streaming support
  class HTTP2Client < Micro::Core::Client
    def initialize(@transport : Transport)
      super
    end

    def call(request : Micro::Core::TransportRequest) : Micro::Core::TransportResponse
      # Create socket
      socket = transport.dial(request.service)

      begin
        # Create message
        headers = request.headers.dup
        headers["content-type"] = request.content_type
        headers["service"] = request.service
        headers["method"] = request.method

        message = Micro::Core::Message.new(
          body: request.body,
          type: Micro::Core::MessageType::Request,
          headers: headers,
          endpoint: "/#{request.service}/#{request.method}"
        )

        # Send request
        socket.send(message)

        # Receive response
        response = socket.receive(request.timeout)

        if response
          Micro::Core::TransportResponse.new(
            status: response.headers["status"]?.try(&.to_i) || 200,
            body: response.body,
            content_type: response.headers["content-type"]? || "application/octet-stream",
            headers: response.headers
          )
        else
          Micro::Core::TransportResponse.new(
            status: 504,
            error: "Request timeout"
          )
        end
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

      # For HTTP/2, we need to create a special streaming socket
      socket = transport.dial(service)

      # Create initial headers for the stream
      headers = opts.headers.dup
      headers["service"] = service
      headers["method"] = method
      headers["x-stream"] = "true" # Indicate this is a streaming request

      # Create and return HTTP/2 stream wrapper
      HTTP2ClientStream.new(socket, headers, "/#{service}/#{method}")
    end
  end

  # HTTP/2 client stream wrapper
  class HTTP2ClientStream < Micro::Core::Stream
    @socket : Micro::Core::Socket
    @headers : HTTP::Headers
    @headers_sent = false
    @closed = false
    @send_closed = false

    def initialize(@socket : Micro::Core::Socket, headers : HTTP::Headers, @endpoint : String)
      super()
      # Copy headers to metadata
      headers.each { |k, v| @metadata[k] = v }
      @headers = headers
    end

    def send(body : Bytes) : Nil
      raise Micro::Core::TransportError.new("Stream is closed", Micro::Core::ErrorCode::ConnectionReset) if @send_closed

      # Send headers on first send
      if @headers_sent
        # For subsequent sends, create a data-only message
        message = Micro::Core::Message.new(
          body: body,
          type: Micro::Core::MessageType::Event,
          headers: {"x-stream-id" => @id},
          id: @id
        )
        @socket.send(message)
      else
        message = Micro::Core::Message.new(
          body: body,
          type: Micro::Core::MessageType::Request,
          headers: @headers,
          endpoint: @endpoint,
          id: @id
        )
        @socket.send(message)
        @headers_sent = true
      end
    end

    def receive : Bytes
      response = @socket.receive

      # Update metadata from response headers
      response.headers.each { |k, v| @metadata[k] = v }

      response.body
    end

    def receive(timeout : Time::Span) : Bytes?
      response = @socket.receive(timeout)
      return nil unless response

      # Update metadata from response headers
      response.headers.each { |k, v| @metadata[k] = v }

      response.body
    end

    def close : Nil
      return if @closed
      close_send
      @closed = true
      @socket.close
    end

    def closed? : Bool
      @closed
    end

    def close_send : Nil
      return if @send_closed
      @send_closed = true

      # Send end-of-stream message
      if @headers_sent
        message = Micro::Core::Message.new(
          body: Bytes.empty,
          type: Micro::Core::MessageType::Event,
          headers: {"x-stream-id" => @id, "x-stream-end" => "true"},
          id: @id
        )
        @socket.send(message)
      end
    end

    def send_closed? : Bool
      @send_closed
    end
  end
end
