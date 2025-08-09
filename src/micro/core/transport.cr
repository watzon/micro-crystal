require "http/headers"
require "uuid"
require "./box"
require "../stdlib/tls_config"

module Micro::Core
  # Transport handles communication between services
  # It provides an abstraction layer over different protocols (HTTP, gRPC, TCP, etc.)
  abstract class Transport
    # Transport options for configuration
    struct Options
      property address : String
      property timeout : Time::Span
      property secure : Bool
      property metadata : HTTP::Headers
      # TLS configuration object (must be duck-typed)
      property tls_config : Micro::Stdlib::TLSConfig?

      def initialize(
        @address : String = "0.0.0.0:0",
        @timeout : Time::Span = 30.seconds,
        @secure : Bool = false,
        @metadata : HTTP::Headers = HTTP::Headers.new,
        @tls_config : Micro::Stdlib::TLSConfig? = nil,
      )
      end

      # Check if TLS config is present
      def tls_config? : Bool
        !@tls_config.nil?
      end
    end

    getter options : Options
    getter? started : Bool = false

    def initialize(@options : Options)
    end

    # Start the transport
    abstract def start : Nil

    # Stop the transport
    abstract def stop : Nil

    # Create a new listener for accepting connections
    abstract def listen(address : String) : Listener

    # Dial a connection to a remote address
    abstract def dial(address : String, opts : DialOptions? = nil) : Socket

    # Get the transport address
    abstract def address : String

    # Transport protocol name (http, grpc, tcp, etc.)
    abstract def protocol : String
  end

  # DialOptions for outgoing connections
  struct DialOptions
    property timeout : Time::Span
    property secure : Bool
    property metadata : HTTP::Headers
    # TLS configuration object (must be duck-typed)
    property tls_config : Micro::Stdlib::TLSConfig?

    def initialize(
      @timeout : Time::Span = 30.seconds,
      @secure : Bool = false,
      @metadata : HTTP::Headers = HTTP::Headers.new,
      @tls_config : Box? = nil,
    )
    end

    # Check if TLS config is present
    def tls_config? : Bool
      !@tls_config.nil?
    end
  end

  # Message represents a transport message
  class Message
    # Message headers
    property headers : HTTP::Headers

    # Message body
    property body : Bytes

    # Message type (request, response, event, etc.)
    property type : MessageType

    # Message ID for correlation
    property id : String

    # Target service and endpoint
    property target : String?
    property endpoint : String?

    # Reply address for responses
    property reply_to : String?

    def initialize(
      @body : Bytes,
      @type : MessageType = MessageType::Request,
      @headers : HTTP::Headers = HTTP::Headers.new,
      @id : String = UUID.random.to_s,
      @target : String? = nil,
      @endpoint : String? = nil,
      @reply_to : String? = nil,
    )
    end

    # Get a header value
    def [](key : String) : String?
      headers[key]?
    end

    # Set a header value
    def []=(key : String, value : String) : String
      headers[key] = value
    end
  end

  # Message types
  enum MessageType
    Request
    Response
    Event
    Error
  end

  # Socket represents a bidirectional communication channel
  abstract class Socket
    # Local address
    abstract def local_address : String

    # Remote address
    abstract def remote_address : String

    # Send a message
    abstract def send(message : Message) : Nil

    # Receive a message (blocking)
    abstract def receive : Message

    # Receive a message with timeout
    abstract def receive(timeout : Time::Span) : Message?

    # Close the connection
    abstract def close : Nil

    # Check if socket is closed
    abstract def closed? : Bool

    # Set read timeout
    abstract def read_timeout=(timeout : Time::Span) : Nil

    # Set write timeout
    abstract def write_timeout=(timeout : Time::Span) : Nil
  end

  # Listener accepts incoming connections
  abstract class Listener
    # Local address the listener is bound to
    abstract def address : String

    # Accept a new connection (blocking)
    abstract def accept : Socket

    # Accept with timeout
    abstract def accept(timeout : Time::Span) : Socket?

    # Close the listener
    abstract def close : Nil

    # Check if listener is closed
    abstract def closed? : Bool
  end

  # TransportError represents transport-level errors
  class TransportError < Exception
    # Error code
    getter code : ErrorCode

    # Whether the error is temporary
    getter? temporary : Bool

    def initialize(message : String, @code : ErrorCode = ErrorCode::Unknown, @temporary : Bool = false)
      super(message)
    end
  end

  # Transport error codes
  enum ErrorCode
    Unknown
    Timeout
    ConnectionRefused
    ConnectionReset
    NetworkUnreachable
    ServiceUnavailable
    InvalidMessage
    Unauthorized
    Forbidden
    NotFound
    InternalError
  end

  # Transport request for RPC calls
  class TransportRequest
    # Service name
    property service : String

    # Method/endpoint name
    property method : String

    # Request headers
    property headers : HTTP::Headers

    # Request body
    property body : Bytes

    # Content type
    property content_type : String

    # Request timeout
    property timeout : Time::Span

    def initialize(
      @service : String,
      @method : String,
      @body : Bytes,
      @content_type : String = "application/json",
      @headers : HTTP::Headers = HTTP::Headers.new,
      @timeout : Time::Span = 30.seconds,
    )
    end
  end

  # Transport response for RPC calls
  class TransportResponse
    # Status code
    property status : Int32

    # Response headers
    property headers : HTTP::Headers

    # Response body
    property body : Bytes

    # Content type
    property content_type : String

    # Error if any
    property error : String?

    def initialize(
      @status : Int32 = 200,
      @body : Bytes = Bytes.empty,
      @content_type : String = "application/json",
      @headers : HTTP::Headers = HTTP::Headers.new,
      @error : String? = nil,
    )
    end

    # Check if response is successful
    def success? : Bool
      status >= 200 && status < 300
    end

    # Check if response is an error
    def error? : Bool
      !success? || !error.nil?
    end
  end

  # Client for making RPC calls
  abstract class Client
    # Transport used by the client
    getter transport : Transport

    def initialize(@transport : Transport)
    end

    # Call a remote service method
    abstract def call(request : TransportRequest) : TransportResponse

    # Call a remote service method with options
    abstract def call(service : String, method : String, body : Bytes, opts : CallOptions? = nil) : TransportResponse

    # Stream call for bidirectional streaming
    abstract def stream(service : String, method : String, opts : CallOptions? = nil) : Stream
  end

  # Options for RPC calls
  struct CallOptions
    property timeout : Time::Span
    property headers : HTTP::Headers
    property retry_count : Int32
    property retry_delay : Time::Span

    def initialize(
      @timeout : Time::Span = 30.seconds,
      @headers : HTTP::Headers = HTTP::Headers.new,
      @retry_count : Int32 = 0,
      @retry_delay : Time::Span = 1.second,
    )
    end
  end

  # Stream for bidirectional communication
  abstract class Stream
    # Stream metadata (headers)
    getter metadata : HTTP::Headers = HTTP::Headers.new

    # Stream ID for correlation
    property id : String = UUID.random.to_s

    # Send a message on the stream
    abstract def send(body : Bytes) : Nil

    # Receive a message from the stream
    abstract def receive : Bytes

    # Receive with timeout
    abstract def receive(timeout : Time::Span) : Bytes?

    # Close the stream
    abstract def close : Nil

    # Check if stream is closed
    abstract def closed? : Bool

    # Close sending side only
    abstract def close_send : Nil

    # Check if send side is closed
    abstract def send_closed? : Bool

    # Send a message with headers
    def send(body : Bytes, headers : HTTP::Headers) : Nil
      # Default implementation - transports can override if they support headers per message
      headers.each { |k, v| metadata[k] = v }
      send(body)
    end

    # Send an error and close the stream
    def send_error(error : String) : Nil
      metadata["error"] = error
      close
    end
  end

  # Server handles incoming requests
  abstract class Server
    # Transport used by the server
    getter transport : Transport

    # Server options
    getter options : ServerOptions

    def initialize(@transport : Transport, @options : ServerOptions)
    end

    # Start the server
    abstract def start : Nil

    # Stop the server
    abstract def stop : Nil

    # Handle incoming requests
    abstract def handle(handler : RequestHandler) : Nil

    # Server address
    abstract def address : String
  end

  # Server configuration options
  struct ServerOptions
    property address : String
    property advertise : String?
    property max_connections : Int32
    property read_timeout : Time::Span
    property write_timeout : Time::Span
    property metadata : HTTP::Headers

    def initialize(
      @address : String = "0.0.0.0:0",
      @advertise : String? = nil,
      @max_connections : Int32 = 1000,
      @read_timeout : Time::Span = 30.seconds,
      @write_timeout : Time::Span = 30.seconds,
      @metadata : HTTP::Headers = HTTP::Headers.new,
    )
    end
  end

  # Request handler function
  alias RequestHandler = Proc(TransportRequest, TransportResponse)

  # StreamHandler handles bidirectional streaming communication
  abstract class StreamHandler
    # Handle an incoming stream connection
    # The stream will be closed automatically when this method returns
    abstract def handle(stream : Stream, request : TransportRequest) : Nil

    # Called when a stream error occurs
    def on_error(stream : Stream, error : Exception) : Nil
      # Default implementation - subclasses can override
    end

    # Called when the stream is closed
    def on_close(stream : Stream) : Nil
      # Default implementation - subclasses can override
    end
  end

  # Streaming server support
  abstract class StreamingServer < Server
    # Handle incoming streaming requests
    abstract def handle_stream(path : String, handler : StreamHandler) : Nil

    # Remove a stream handler
    abstract def remove_stream_handler(path : String) : Nil
  end
end
