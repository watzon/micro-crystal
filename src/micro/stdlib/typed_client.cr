# Typed client implementation that uses macro-generated stubs
# This provides a type-safe way to call RPC services

require "./client"
require "../core/transport"
require "../core/codec"
require "../macros/client_stubs"

module Micro::Stdlib
  # Base class for typed RPC clients
  # Extend this class and use `generate_client_for` macro to create
  # type-safe client methods for a service interface
  #
  # Example:
  # ```
  # class CalculatorClient < Micro::Stdlib::TypedClient
  #   generate_client_for(CalculatorService)
  # end
  #
  # client = CalculatorClient.new(transport, "localhost:8080")
  # result = client.add(AddParams.new(5, 3)) # Type-safe!
  # ```
  abstract class TypedClient
    include Micro::Macros::ClientStubs

    @transport : Micro::Core::Transport
    @address : String
    @codec : Micro::Core::Codec
    @timeout : Time::Span

    def initialize(
      @transport : Micro::Core::Transport,
      @address : String,
      codec : Micro::Core::Codec? = nil,
      @timeout : Time::Span = 30.seconds,
    )
      @codec = codec || Micro::Core::CodecRegistry.get("application/json") ||
               raise "No JSON codec registered"
    end

    # Implementation of abstract methods from ClientStubs
    def call(request : Micro::Core::Request) : Micro::Core::Response
      socket = @transport.dial(@address)

      begin
        # Create transport message
        headers = request.headers.dup
        headers["Content-Type"] = request.content_type
        headers["X-Timeout"] = @timeout.total_seconds.to_s

        # Convert body to bytes if needed
        body = case request.body
               when Bytes
                 request.body
               when JSON::Any
                 @codec.marshal(request.body)
               else
                 Bytes.empty
               end

        message = Micro::Core::Message.new(
          type: Micro::Core::MessageType::Request,
          target: request.service,
          endpoint: request.endpoint,
          body: body,
          headers: headers
        )

        # Send request
        socket.send(message)

        # Receive response
        response_message = socket.receive

        # Check for errors
        if status_code = response_message.headers["X-Status-Code"]?
          status = status_code.to_i

          if status >= 400
            # Extract error message
            error_body = response_message.body
            error_msg = if error_body.size > 0
                          begin
                            error_data = @codec.unmarshal(error_body, Hash(String, String))
                            error_data["error"]? || "Unknown error"
                          rescue
                            String.new(error_body)
                          end
                        else
                          "HTTP #{status}"
                        end

            raise Micro::Core::ClientError.new(error_msg, status)
          end
        end

        # Convert to response
        Micro::Core::Response.new(
          status: response_message.headers["X-Status-Code"]?.try(&.to_i) || 200,
          body: response_message.body,
          headers: response_message.headers
        )
      ensure
        socket.close
      end
    end

    def call_stream(request : Micro::Core::Request) : Micro::Core::Stream
      socket = @transport.dial(@address)

      # Check if transport supports streaming
      unless socket.responds_to?(:stream)
        raise "Transport does not support streaming"
      end

      # Create stream
      stream = socket.stream(
        service: request.service,
        method: request.endpoint
      )

      # Send initial request if there's a body
      if body = request.body
        stream.send(body)
      end

      stream
    end

    def codec : Micro::Core::Codec
      @codec
    end

    # Convenience method to use a different codec
    def with_codec(codec : Micro::Core::Codec) : self
      @codec = codec
      self
    end

    # Convenience method to set timeout
    def with_timeout(timeout : Time::Span) : self
      @timeout = timeout
      self
    end
  end
end
