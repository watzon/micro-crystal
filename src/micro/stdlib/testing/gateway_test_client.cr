require "../../gateway/api_gateway"
require "../../gateway/middleware/cors_handler"
require "../../gateway/config"
require "../../gateway/service_proxy"
require "../transports/loopback_transport"
require "../client"

module Micro::Stdlib::Testing
  # A client that executes requests through the API Gateway's routing logic
  # entirely in-process, without binding a TCP port.
  class GatewayTestClient
    getter gateway : Micro::Gateway::APIGateway

    # Map of service name -> loopback address (e.g. "loopback://catalog")
    getter service_addresses : Hash(String, String)

    @routing_client : RoutingClient
    @use_cors : Bool

    def initialize(
      config : Micro::Gateway::Config,
      service_addresses : Hash(String, String)? = nil,
      use_cors : Bool = true,
    )
      # Build gateway from config
      @gateway = Micro::Gateway::APIGateway.new(config)

      # Default mapping: loopback://<service-name>
      @service_addresses = service_addresses || begin
        mapping = {} of String => String
        config.services.keys.each { |name| mapping[name] = "loopback://#{name}" }
        mapping
      end

      # Shared loopback transport and routing-aware client
      transport = Micro::Stdlib::Transports::LoopbackTransport.new(
        Micro::Core::Transport::Options.new
      )

      @routing_client = RoutingClient.new(transport, @service_addresses)
      @use_cors = use_cors

      # Replace service proxies with testing subclass that uses routing client
      @gateway.services.keys.each do |name|
        if svc = @gateway.services[name]?
          test_proxy = TestServiceProxy.new(name, svc.config, config.registry, @routing_client)
          @gateway.services[name] = test_proxy
        end
      end
    end

    # Perform an HTTP-like request through the gateway.
    # Returns a tuple: {status_code, headers, body_string}
    def request(method : String, path : String, body : String = "", headers : HTTP::Headers = HTTP::Headers.new)
      req = if body.empty?
              HTTP::Request.new(method, path, headers)
            else
              HTTP::Request.new(method, path, headers, IO::Memory.new(body))
            end
      io = IO::Memory.new
      res = HTTP::Server::Response.new(io)
      ctx = HTTP::Server::Context.new(req, res)

      # For testing, directly call handle_request (CORS tested separately)
      @gateway.handle_request(ctx)

      # Flush and collect response (raw HTTP response written by HTTP::Server::Response)
      res.flush
      io.rewind
      raw = io.gets_to_end

      # Extract body from raw HTTP response bytes
      body_str = parse_http_body(raw)

      {res.status_code, res.headers, body_str}
    end

    # Convenience for JSON requests
    def request_json(method : String, path : String, payload : JSON::Any | Hash(String, _) | Nil = nil, headers : HTTP::Headers = HTTP::Headers.new)
      headers = headers.dup
      headers["Content-Type"] = "application/json"
      body = payload.nil? ? "" : (payload.is_a?(JSON::Any) ? payload.to_json : payload.to_json)
      status, res_headers, res_body = request(method, path, body, headers)
      {status, res_headers, res_body.size > 0 ? JSON.parse(res_body) : JSON::Any.new({} of String => JSON::Any)}
    end

    # A client that routes per-service using provided address mapping
    class RoutingClient < Micro::Stdlib::Client
      @routes : Hash(String, String)

      def initialize(transport : Micro::Core::Transport, routes : Hash(String, String))
        super(transport)
        @routes = routes
      end

      def call(request : Micro::Core::TransportRequest) : Micro::Core::TransportResponse
        address = @routes[request.service]?
        unless address
          return Micro::Core::TransportResponse.new(
            status: 503,
            body: %({"error":"No route for service '#{request.service}'"}).to_slice,
            content_type: "application/json",
            error: "No route for service"
          )
        end

        socket = transport.dial(address)
        begin
          # Build message and exchange like base client
          headers = request.headers.dup
          headers["Content-Type"] = request.content_type
          message = Micro::Core::Message.new(
            body: request.body,
            type: Micro::Core::MessageType::Request,
            headers: headers,
            target: request.service,
            endpoint: request.method
          )

          socket.send(message)
          response_message = socket.receive(request.timeout)
          unless response_message
            return Micro::Core::TransportResponse.new(
              status: 504,
              body: %({"error":"Request timeout"}).to_slice,
              content_type: "application/json",
              error: "Request timeout"
            )
          end

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
        ensure
          socket.close unless socket.closed?
        end
      end
    end

    # ServiceProxy subclass that uses a provided client instead of creating HTTP-based client
    class TestServiceProxy < Micro::Gateway::ServiceProxy
      def initialize(name : String, config : Micro::Gateway::ServiceConfig, registry : Micro::Core::Registry::Base?, client : Micro::Stdlib::Client)
        super(name, config, registry)
        @client = client
      end
    end

    private def parse_http_body(raw : String) : String
      # Find end of headers (\r\n\r\n preferred, fallback to \n\n)
      sep = raw.index("\r\n\r\n")
      offset = 4
      unless sep
        sep = raw.index("\n\n")
        offset = 2
      end
      return raw unless sep

      headers_str = raw[0, sep]
      body_part = raw[sep + offset, raw.size - (sep + offset)]

      # Detect chunked transfer
      if headers_str.includes?("Transfer-Encoding: chunked")
        return parse_chunked_body(body_part)
      else
        return body_part
      end
    end

    private def parse_chunked_body(chunked : String) : String
      i = 0
      out = String.build do |io|
        while i < chunked.size
          line_end = chunked.index("\r\n", i) || chunked.index("\n", i)
          break unless line_end
          size_hex = chunked[i, line_end - i]
          size = size_hex.to_i(16)
          i = (chunked[line_end, 2] == "\r\n") ? line_end + 2 : line_end + 1
          break if size == 0
          io << chunked[i, size]
          i += size
          # Skip trailing CRLF after chunk
          if chunked[i, 2] == "\r\n"
            i += 2
          elsif chunked[i, 1] == "\n"
            i += 1
          end
        end
      end
      out
    end
  end
end
