require "../../core/transport"
require "../../core/codec"
require "../service"
require "../client"
require "../codecs/json"
require "../transports/loopback_transport"

module Micro::Stdlib::Testing
  # In-process harness to run a service and invoke handlers without starting a network server
  class ServiceHarness
    getter service : Micro::Stdlib::Service
    getter transport : Micro::Stdlib::Transports::LoopbackTransport
    getter client : Micro::Stdlib::Client
    getter address : String

    @prev_server_env : String?

    # Initialize without a block (no auto-start)
    def initialize(
      name : String,
      version : String = "latest",
      address : String? = nil,
      codec : Micro::Core::Codec = Micro::Stdlib::Codecs::JSON.new,
    )
      resolved_address = address || self.class.default_address_for(name)
      @address = normalize_address(resolved_address)

      transport_options = Micro::Core::Transport::Options.new(address: @address)
      @transport = Micro::Stdlib::Transports::LoopbackTransport.new(transport_options)

      service_options = Micro::Core::Service::Options.new(
        name: name,
        version: version,
        transport: @transport,
        codec: codec,
        registry: nil,
        broker: nil,
        pubsub: nil
      )

      @service = Micro::Stdlib::Service.new(service_options)
      @client = Micro::Stdlib::Client.new(@transport)
      @prev_server_env = nil
    end

    # Convenience builder: yield in the context of the harness, auto-start, and return it
    def self.build(
      name : String,
      version : String = "latest",
      address : String? = nil,
      codec : Micro::Core::Codec = Micro::Stdlib::Codecs::JSON.new,
      &
    ) : ServiceHarness
      h = new(name, version, address, codec)
      with h yield
      h.start
      h
    end

    # Register a handler on the underlying service
    def handle(endpoint : String, &block : Micro::Core::Context ->)
      @service.handle(endpoint, block)
      self
    end

    # Start the service in-process using the loopback transport
    def start : self
      # Ensure server binds to the loopback address via env hook used by Stdlib::Service
      @prev_server_env = ENV["MICRO_SERVER_ADDRESS"]?
      ENV["MICRO_SERVER_ADDRESS"] = @address

      @service.start
      self
    end

    # Stop the service and restore env
    def stop : Nil
      begin
        @service.stop
      ensure
        if prev = @prev_server_env
          ENV["MICRO_SERVER_ADDRESS"] = prev
        else
          ENV.delete("MICRO_SERVER_ADDRESS")
        end
      end
    end

    # Invoke an endpoint on the service using raw bytes
    def call(method : String, body : Bytes = Bytes.empty, *, content_type : String = "application/json", headers : HTTP::Headers = HTTP::Headers.new, timeout : Time::Span = 5.seconds) : Micro::Core::TransportResponse
      request = Micro::Core::TransportRequest.new(
        service: @service.options.name,
        method: method,
        body: body,
        content_type: content_type,
        headers: headers,
        timeout: timeout
      )
      @client.call(request)
    end

    # JSON convenience: marshal the payload and set content-type
    def call_json(method : String, payload : _ = {} of String => String, *, accept : String = "application/json", timeout : Time::Span = 5.seconds) : Micro::Core::TransportResponse
      headers = HTTP::Headers.new
      headers["Accept"] = accept
      body = Micro::Core::MessageEncoder.response_body_to_bytes(payload)
      call(method, body, content_type: "application/json", headers: headers, timeout: timeout)
    end

    private def normalize_address(address : String) : String
      return address if address.starts_with?("loopback://")
      "loopback://#{address}"
    end

    def self.default_address_for(name : String) : String
      # Use a stable, namespaced address per service name
      "loopback://#{name}"
    end
  end
end
