require "../core/transport"
require "../core/codec"
require "../core/registry"
require "../core/selector"
require "../core/message_encoder"
require "./client"

module Micro::Stdlib
  # Client with integrated service discovery
  class DiscoveryClient < Client
    @registry : Micro::Core::Registry::Base?
    @selector : Micro::Core::Selector?

    def initialize(@transport : Micro::Core::Transport, @registry : Micro::Core::Registry::Base? = nil, @selector : Micro::Core::Selector? = nil)
      super(@transport)
    end

    def call(request : Micro::Core::TransportRequest) : Micro::Core::TransportResponse
      # If we have a registry, use it to discover the service
      if registry = @registry
        service_name = request.service

        # Get services from registry (use "*" for any version)
        services = registry.get_service(service_name, "*")

        if services.empty?
          error_info = Micro::Core::MessageEncoder.error_response("Service not found: #{service_name}", 503)
          return Micro::Core::TransportResponse.new(
            status: error_info[:status],
            body: error_info[:body],
            content_type: error_info[:content_type],
            error: "Service not found: #{service_name}"
          )
        end

        # Collect all nodes from all service instances
        all_nodes = services.flat_map(&.nodes)

        if all_nodes.empty?
          error_info = Micro::Core::MessageEncoder.error_response("No available nodes for service: #{service_name}", 503)
          return Micro::Core::TransportResponse.new(
            status: error_info[:status],
            body: error_info[:body],
            content_type: error_info[:content_type],
            error: "No available nodes for service: #{service_name}"
          )
        end

        # Use selector to pick a node
        node = if selector = @selector
                 selector.select(all_nodes)
               else
                 # Simple random selection as default
                 all_nodes.sample
               end

        # Build address from node
        address = "#{node.address}:#{node.port}"

        # Create a new request with the discovered address
        discovered_request = Micro::Core::TransportRequest.new(
          service: request.service,
          method: request.method,
          body: request.body,
          headers: request.headers,
          content_type: request.content_type,
          timeout: request.timeout
        )

        # Dial using discovered address
        socket = @transport.dial(address)

        begin
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
        ensure
          socket.close unless socket.closed?
        end
      else
        # No registry, fall back to parent implementation
        super
      end
    end
  end
end
