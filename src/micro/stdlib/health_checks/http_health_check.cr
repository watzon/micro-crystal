require "../../core/health_check"
require "../../core/transport"
require "../transports/http"

module Micro::Stdlib::HealthChecks
  # HTTP health check using HEAD request
  class HTTPHeadHealthCheck < Micro::Core::HealthCheckStrategy
    getter path : String
    getter expected_status : Range(Int32, Int32)

    def initialize(@path : String = "/health", @expected_status : Range(Int32, Int32) = 200..299)
    end

    def check(socket : Micro::Core::Socket) : Bool
      return false if socket.closed?

      # Try to perform a HEAD request
      begin
        # Send HEAD request
        message = Micro::Core::Message.new(
          body: Bytes.empty,
          type: Micro::Core::MessageType::Request,
          headers: HTTP::Headers{
            "X-HTTP-Method"  => "HEAD",
            "X-HTTP-Path"    => @path,
            "X-Health-Check" => "true",
          }
        )

        socket.send(message)

        # Wait for response with short timeout
        response = socket.receive(2.seconds)
        return false unless response

        # Check status code from headers
        status_str = response.headers["X-Status-Code"]?
        if status_str
          status = status_str.to_i
          @expected_status.includes?(status)
        else
          # No status means error
          false
        end
      rescue
        false
      end
    end

    def description : String
      "HTTP HEAD #{@path} (expect #{@expected_status})"
    end
  end

  # HTTP health check using custom ping endpoint
  class HTTPPingHealthCheck < Micro::Core::HealthCheckStrategy
    getter endpoint : String
    getter expected_response : String?

    def initialize(@endpoint : String = "health.ping", @expected_response : String? = nil)
    end

    def check(socket : Micro::Core::Socket) : Bool
      return false if socket.closed?

      begin
        # Send ping request
        message = Micro::Core::Message.new(
          body: Bytes.empty,
          type: Micro::Core::MessageType::Request,
          endpoint: @endpoint,
          headers: HTTP::Headers{"X-Health-Check" => "true"}
        )

        socket.send(message)

        # Wait for response
        response = socket.receive(2.seconds)
        return false unless response

        if response.type.response?
          if expected = @expected_response
            # Check response body matches
            String.new(response.body) == expected
          else
            # Just check we got a successful response
            true
          end
        else
          false
        end
      rescue
        false
      end
    end

    def description : String
      "HTTP ping endpoint '#{@endpoint}'"
    end
  end

  # Composite health check that tries multiple strategies
  class CompositeHealthCheck < Micro::Core::HealthCheckStrategy
    getter strategies : Array(Micro::Core::HealthCheckStrategy)
    getter require_all : Bool

    def initialize(@strategies : Array(Micro::Core::HealthCheckStrategy), @require_all : Bool = false)
      raise ArgumentError.new("Must provide at least one strategy") if @strategies.empty?
    end

    def check(socket : Micro::Core::Socket) : Bool
      if @require_all
        # All must pass
        @strategies.all?(&.check(socket))
      else
        # At least one must pass
        @strategies.any?(&.check(socket))
      end
    end

    def description : String
      mode = @require_all ? "all of" : "any of"
      "Composite check (#{mode}: #{@strategies.map(&.description).join(", ")})"
    end
  end
end
