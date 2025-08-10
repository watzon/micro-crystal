require "../../core/transport"
require "../../core/closable_resource"
require "../../core/fiber_tracker"

module Micro::Stdlib::Transports
  # Simple in-process, no-network transport for tests and local harnesses
  # Provides request/response behavior using paired in-memory sockets
  class LoopbackTransport < Micro::Core::Transport
    def protocol : String
      "loopback"
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
      normalized = normalize_address(address)
      LoopbackListener.new(normalized)
    end

    def dial(address : String, opts : Micro::Core::DialOptions? = nil) : Micro::Core::Socket
      normalized = normalize_address(address)
      listener = LoopbackBus.get(normalized)
      unless listener
        raise Micro::Core::TransportError.new(
          "No loopback listener for #{normalized}", Micro::Core::ErrorCode::ServiceUnavailable
        )
      end

      client_socket, server_socket = LoopbackConnectionPair.create(normalized)

      # Deliver the server side to the listener's accept queue
      listener.enqueue(server_socket)

      client_socket
    end

    private def normalize_address(address : String) : String
      return address if address.starts_with?("loopback://")
      "loopback://#{address}"
    end
  end

  # Global in-process bus mapping addresses to listeners
  module LoopbackBus
    extend self

    @@mutex = Mutex.new
    @@listeners = {} of String => LoopbackListener

    def register(address : String, listener : LoopbackListener) : Nil
      @@mutex.synchronize { @@listeners[address] = listener }
    end

    def unregister(address : String) : Nil
      @@mutex.synchronize { @@listeners.delete(address) }
    end

    def get(address : String) : LoopbackListener?
      @@mutex.synchronize { @@listeners[address]? }
    end
  end

  # Listener that accepts loopback socket pairs
  class LoopbackListener < Micro::Core::Listener
    include Micro::Core::ClosableResource

    getter address : String

    @accept_channel = Channel(LoopbackServerSocket).new(64)

    def initialize(@address : String)
      LoopbackBus.register(@address, self)
    end

    # Internal API used by transport to deliver server-side sockets
    def enqueue(socket : LoopbackServerSocket) : Nil
      return if closed?
      begin
        @accept_channel.send(socket)
      rescue Channel::ClosedError
        # Listener closed while enqueuing; close socket
        socket.close
      end
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
      when s = @accept_channel.receive
        s
      when timeout(timeout)
        nil
      end
    rescue Channel::ClosedError
      close
      nil
    end

    def close : Nil
      super
    end

    def perform_close : Nil
      @accept_channel.close
      LoopbackBus.unregister(@address)
    end
  end

  # Simple bi-directional in-memory connection using channels
  module LoopbackConnectionPair
    extend self

    def create(remote_address : String)
      c2s = Channel(Micro::Core::Message).new(16)
      s2c = Channel(Micro::Core::Message).new(16)

      client = LoopbackClientSocket.new(local_address: "loopback://client", remote_address: remote_address, outbound: c2s, inbound: s2c)
      server = LoopbackServerSocket.new(local_address: remote_address, remote_address: "loopback://client", outbound: s2c, inbound: c2s)

      {client, server}
    end
  end

  abstract class BaseLoopbackSocket < Micro::Core::Socket
    getter local_address : String
    getter remote_address : String

    @inbound : Channel(Micro::Core::Message)
    @outbound : Channel(Micro::Core::Message)
    @closed = false
    @read_timeout : Time::Span = 30.seconds
    @write_timeout : Time::Span = 30.seconds

    def initialize(@local_address : String, @remote_address : String, @outbound : Channel(Micro::Core::Message), @inbound : Channel(Micro::Core::Message))
    end

    def send(message : Micro::Core::Message) : Nil
      return if closed?
      begin
        # Ignore write timeout for now; channel has bounded capacity
        @outbound.send(message)
      rescue Channel::ClosedError
        @closed = true
        raise Micro::Core::TransportError.new("Connection closed", Micro::Core::ErrorCode::ConnectionReset)
      end
    end

    def receive : Micro::Core::Message
      check_open!
      @inbound.receive
    rescue Channel::ClosedError
      @closed = true
      raise Micro::Core::TransportError.new("Connection closed", Micro::Core::ErrorCode::ConnectionReset)
    end

    def receive(timeout : Time::Span) : Micro::Core::Message?
      check_open!
      select
      when m = @inbound.receive
        m
      when timeout(timeout)
        nil
      end
    rescue Channel::ClosedError
      @closed = true
      nil
    end

    def close : Nil
      return if @closed
      @closed = true
      # Close both directions to unblock the peer
      @inbound.close
      @outbound.close
    end

    def closed? : Bool
      @closed
    end

    def read_timeout=(timeout : Time::Span) : Nil
      @read_timeout = timeout
    end

    def write_timeout=(timeout : Time::Span) : Nil
      @write_timeout = timeout
    end

    private def check_open!
      if closed?
        raise Micro::Core::TransportError.new("Connection closed", Micro::Core::ErrorCode::ConnectionReset)
      end
    end
  end

  class LoopbackClientSocket < BaseLoopbackSocket
  end

  class LoopbackServerSocket < BaseLoopbackSocket
  end
end
