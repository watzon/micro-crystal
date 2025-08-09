require "../core/transport"
require "../core/codec"
require "../core/pool"
require "../core/message_encoder"
require "../core/errors"
require "./pools/http_pool"

module Micro::Stdlib
  # HTTP-based client implementation
  class Client < Micro::Core::Client
    # Optional connection pool for reusing connections
    getter pool : Micro::Core::ConnectionPool?

    # Pool configuration used when pool is enabled
    getter pool_config : Micro::Core::ConnectionPool::Config?

    def initialize(@transport : Micro::Core::Transport, @pool_config : Micro::Core::ConnectionPool::Config? = nil)
      super(@transport)
      @pool = nil
    end

    # Enable connection pooling for the specified address
    # This creates a pool that will be reused for all calls to this address
    def enable_pooling(address : String) : Nil
      return if @pool # Already enabled

      config = @pool_config || Micro::Core::ConnectionPool::Config.new

      # Ensure we have HTTP transport for pooling
      unless @transport.is_a?(Micro::Stdlib::Transports::HTTPTransport)
        raise ArgumentError.new("Connection pooling only supported for HTTP transport")
      end

      http_transport = @transport.as(Micro::Stdlib::Transports::HTTPTransport)
      factory = Micro::Stdlib::Pools::HTTPConnectionFactory.new(http_transport, address)
      @pool = Micro::Stdlib::Pools::HTTPConnectionPool.new(config, factory)
    end

    # Disable connection pooling and close existing pool
    def disable_pooling : Nil
      @pool.try(&.close)
      @pool = nil
    end

    # Check if pooling is enabled
    def pooling_enabled? : Bool
      !@pool.nil?
    end

    # Cleanup method - ensure pool is closed when client is finalized
    def finalize
      disable_pooling
    end

    # Graceful shutdown hook for resources held by the client
    def close : Nil
      disable_pooling
    end

    def call(request : Micro::Core::TransportRequest) : Micro::Core::TransportResponse
      # Dial the service
      # For now, we'll use a simple address format
      # In a real implementation, this would use service discovery
      address = ENV["MICRO_SERVER_ADDRESS"]? || "127.0.0.1:8080"

      # Use pooled connection if available, otherwise fall back to direct connection
      if pool = @pool
        call_with_pool(request, pool)
      else
        call_direct(request, address)
      end
    end

    # Handle call using pooled connection
    private def call_with_pool(request : Micro::Core::TransportRequest, pool : Micro::Core::ConnectionPool) : Micro::Core::TransportResponse
      pooled_conn = pool.acquire

      unless pooled_conn
        return Micro::Core::TransportResponse.new(
          status: 503,
          body: %({"error":"Failed to acquire connection from pool"}).to_slice,
          content_type: "application/json",
          error: "Connection pool exhausted"
        )
      end

      begin
        response = call_with_socket(request, pooled_conn.socket)

        # Release connection back to pool (pool will handle health checking)
        pool.release(pooled_conn)

        response
      rescue ex
        # Connection failed, release it (pool will close unhealthy connections)
        pool.release(pooled_conn)

        Micro::Core::TransportResponse.new(
          status: 503,
          body: %({"error":"Connection error: #{ex.message}"}).to_slice,
          content_type: "application/json",
          error: "Connection error"
        )
      end
    end

    # Handle call using direct connection (original behavior)
    private def call_direct(request : Micro::Core::TransportRequest, address : String) : Micro::Core::TransportResponse
      socket = @transport.dial(address)

      begin
        call_with_socket(request, socket)
      ensure
        socket.close unless socket.closed?
      end
    end

    # Common logic for making calls with any socket
    private def call_with_socket(request : Micro::Core::TransportRequest, socket : Micro::Core::Socket) : Micro::Core::TransportResponse
      # Create transport message from request
      headers = request.headers.dup
      headers["Content-Type"] = request.content_type

      message = Micro::Core::Message.new(
        body: request.body,
        type: Micro::Core::MessageType::Request,
        headers: headers,
        target: request.service,
        endpoint: request.method
      )

      # Send request
      socket.send(message)

      # Receive response with timeout
      response_message = socket.receive(request.timeout)

      unless response_message
        return Micro::Core::TransportResponse.new(
          status: 504,
          body: %({"error":"Request timeout"}).to_slice,
          content_type: "application/json",
          error: "Request timeout"
        )
      end

      # Convert to transport response
      status = if status_code = response_message.headers["X-Status-Code"]?
                 status_code.to_i
               else
                 case response_message.type
                 when .error?
                   500
                 else
                   200
                 end
               end

      Micro::Core::TransportResponse.new(
        status: status,
        body: response_message.body,
        content_type: response_message.headers["Content-Type"]? || "application/octet-stream",
        headers: response_message.headers,
        error: response_message.type.error? ? String.new(response_message.body) : nil
      )
    end

    def call(service : String, method : String, body : Bytes, opts : Micro::Core::CallOptions? = nil) : Micro::Core::TransportResponse
      opts ||= Micro::Core::CallOptions.new

      # Convert hash headers to HTTP::Headers
      headers = HTTP::Headers.new
      opts.headers.each { |k, v| headers[k] = v }

      request = Micro::Core::TransportRequest.new(
        service: service,
        method: method,
        body: body,
        headers: headers,
        timeout: opts.timeout
      )

      # Configure retry with exponential backoff
      retry_config = Micro::Core::Errors::RetryConfig.new(
        max_attempts: opts.retry_count + 1, # +1 because it includes the first attempt
        base_delay: opts.retry_delay,
        max_delay: opts.retry_delay * 10 # Cap at 10x the base delay
      )

      begin
        Micro::Core::Errors.with_retry("client.call", retry_config) do
          call(request)
        end
      rescue ex : Exception
        # Check if it's a client error that shouldn't return 503
        status_code = case ex
                      when Micro::Core::ClientError
                        ex.status_code
                      when Micro::Core::TransportError
                        case ex.code
                        when Micro::Core::ErrorCode::Timeout
                          504 # Gateway Timeout
                        when Micro::Core::ErrorCode::ConnectionRefused,
                             Micro::Core::ErrorCode::ConnectionReset,
                             Micro::Core::ErrorCode::NetworkUnreachable
                          503 # Service Unavailable
                        else
                          500 # Internal Server Error
                        end
                      else
                        500
                      end

        # Return error response
        Micro::Core::TransportResponse.new(
          status: status_code,
          body: %({"error":"#{ex.message || ex.class.name}"}).to_slice,
          content_type: "application/json",
          error: ex.message || ex.class.name
        )
      end
    end

    def stream(service : String, method : String, opts : Micro::Core::CallOptions? = nil) : Micro::Core::Stream
      raise NotImplementedError.new("Streaming not yet implemented for HTTP transport")
    end
  end
end
