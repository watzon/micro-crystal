# µCrystal - A batteries-included microservice toolkit for Crystal
require "log"
require "http/headers"
require "json"
require "uuid"

module Micro
  VERSION = "0.1.0"

  # Configure default logger
  Log.setup_from_env(default_level: :info)
end

# Annotations - must be loaded first for compile-time processing
require "./micro/annotations"

# Core interfaces - order matters for dependencies
require "./micro/core/context"
require "./micro/core/codec"
require "./micro/core/transport"
require "./micro/core/registry"
require "./micro/core/registry_store"
require "./micro/core/broker"
require "./micro/core/service"

# Convenience aliases for easier access to core interfaces
module Micro
  # Make core interfaces available at top level for internal use
  alias Context = Core::Context
  alias Request = Core::Request
  alias ServiceResponse = Core::Response # Renamed to avoid conflict with @[Response] annotation
  alias Codec = Core::Codec
  alias CodecRegistry = Core::CodecRegistry

  # Public-facing aliases for common option types (DX: avoid `Core::...` in app code)
  alias ServiceOptions = Core::Service::Options
  alias ServerOptions = Core::ServerOptions
  alias CallOptions = Core::CallOptions
  alias TransportRequest = Core::TransportRequest
  alias TransportResponse = Core::TransportResponse
  alias Stream = Core::Stream
  alias Client = Core::Client

  # Service creation helpers (not conflicting with @[Service] annotation)
  def self.new_service(name : String, version : String = "latest", & : Stdlib::Service -> _) : Core::Service::Base
    options = Core::Service::Options.new(name: name, version: version)
    service = Stdlib::Service.new(options)
    yield service
    service
  end

  def self.new_service(options : Core::Service::Options) : Core::Service::Base
    Stdlib::Service.new(options)
  end

  # Create a new client
  def self.new_client(transport : Core::Transport? = nil) : Core::Client
    transport ||= Stdlib::Transports::HTTPTransport.new(
      Core::Transport::Options.new
    )
    Stdlib::Client.new(transport)
  end

  # Nicer DX: shorter names alongside existing helpers
  def self.client(transport : Core::Transport? = nil) : Core::Client
    new_client(transport)
  end

  # Register a codec with the global registry
  def self.register_codec(codec : Core::Codec) : Nil
    CodecRegistry.register(codec)
  end

  # Convenience factories to avoid reaching into Stdlib/Core from applications
  module Transports
    def self.http(options : Core::Transport::Options = Core::Transport::Options.new) : Core::Transport
      Stdlib::Transports::HTTPTransport.new(options)
    end

    # Provided when websocket transport is available
    def self.websocket(options : Core::Transport::Options = Core::Transport::Options.new) : Core::Transport
      Stdlib::Transports::WebSocketTransport.new(options)
    end

    # In-process transport for tests and harnesses
    def self.loopback(options : Core::Transport::Options = Core::Transport::Options.new) : Core::Transport
      Stdlib::Transports::LoopbackTransport.new(options)
    end
  end

  module Codecs
    def self.json : Core::Codec
      Stdlib::Codecs::JSON.new
    end

    def self.msgpack : Core::Codec
      Stdlib::Codecs::MsgPackCodec.new
    end
  end

  module Registries
    def self.memory : Core::Registry::Base
      Stdlib::Registries::MemoryRegistry.new(Core::Registry::Options.new)
    end

    def self.consul(options : Core::Registry::Options = Core::Registry::Options.new(type: "consul")) : Core::Registry::Base
      Stdlib::Registries::ConsulRegistry.new(options)
    end
  end

  module Brokers
    def self.memory : Core::Broker::Base
      Stdlib::Brokers::MemoryBroker.new
    end

    # NATS broker factory (if dependency is present/configured)
    def self.nats(url : String? = ENV["NATS_URL"]) : Core::Broker::Base
      Stdlib::Brokers::NATSBroker.new(url)
    end
  end
end

# Default implementations will be loaded when available
require "./micro/stdlib/codecs"
require "./micro/stdlib/transports/http"
require "./micro/stdlib/transports/websocket_transport"
require "./micro/stdlib/transports/loopback_transport"
require "./micro/stdlib/transports/websocket_stream"
require "./micro/stdlib/registries/memory_registry"
require "./micro/stdlib/registries/consul"
require "./micro/stdlib/middleware"
require "./micro/stdlib/testing"
require "./micro/stdlib/service"
require "./micro/stdlib/client"

# Macro modules for service registration and code generation
require "./micro/macros"

# Auto-discovery and simplified service creation
require "./micro/service_base"
require "./micro/auto_discovery"
