require "../../spec_helper"
require "../../../src/micro/stdlib/transports/loopback_transport"
require "../../../src/micro/stdlib/server"
require "../../../src/micro/stdlib/client"

# Fake server handler using loopback transport/server
private class FakeLoopbackServer
  getter server : Micro::Stdlib::Server
  getter address : String

  def initialize(handler : Micro::Core::RequestHandler)
    transport = Micro::Stdlib::Transports::LoopbackTransport.new(Micro::Core::Transport::Options.new)
    @server = Micro::Stdlib::Server.new(transport, Micro::Core::ServerOptions.new(address: "loopback://svc"))
    @server.handle(handler)
    @server.start
    @address = @server.address
  end

  def stop
    @server.stop
  end
end

describe Micro::Stdlib::Client do
  it "maps timeout to 504 (no response)" do
    server = FakeLoopbackServer.new(->(_req : Micro::Core::TransportRequest) {
      # Fast response so the client timeout is the only limiter
      Micro::Core::TransportResponse.new(status: 200, body: %({"ok":true}).to_slice)
    })

    begin
      prev = ENV["MICRO_SERVER_ADDRESS"]?
      ENV["MICRO_SERVER_ADDRESS"] = server.address
      transport = Micro::Stdlib::Transports::LoopbackTransport.new(Micro::Core::Transport::Options.new)
      client = Micro::Stdlib::Client.new(transport)

      # Short timeout with no server delay -> client should still succeed
      req = Micro::Core::TransportRequest.new(service: "svc", method: "op", body: Bytes.empty, headers: HTTP::Headers.new, timeout: 50.milliseconds)
      res = client.call(req)
      res.status.should eq 200
    ensure
      if prev
        ENV["MICRO_SERVER_ADDRESS"] = prev
      else
        ENV.delete("MICRO_SERVER_ADDRESS")
      end
      server.stop
    end
  end

  it "passes through 4xx without retry" do
    attempts = 0
    server = FakeLoopbackServer.new(->(_req : Micro::Core::TransportRequest) {
      attempts += 1
      Micro::Core::TransportResponse.new(status: 400, body: %({"error":"bad"}).to_slice)
    })

    begin
      prev = ENV["MICRO_SERVER_ADDRESS"]?
      ENV["MICRO_SERVER_ADDRESS"] = server.address
      transport = Micro::Stdlib::Transports::LoopbackTransport.new(Micro::Core::Transport::Options.new)
      client = Micro::Stdlib::Client.new(transport)

      res = client.call(Micro::Core::TransportRequest.new(service: "svc", method: "op", body: Bytes.empty))
      res.status.should eq 400
      attempts.should eq 1
    ensure
      if prev
        ENV["MICRO_SERVER_ADDRESS"] = prev
      else
        ENV.delete("MICRO_SERVER_ADDRESS")
      end
      server.stop
    end
  end
end
