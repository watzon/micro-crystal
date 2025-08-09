require "json"
require "uuid"
require "http/headers"
require "./box"

module Micro::Core
  # Context carries request/response and other values across API boundaries
  class Context
    # Request being processed
    getter request : Request

    # Response being built
    getter response : Response

    # Metadata associated with the context
    getter metadata : Hash(String, String)

    # Storage for middleware to pass data
    # Uses untyped hash to support any Box type
    @attributes : Hash(String, Box)

    # Error if any occurred during processing
    property error : Exception?

    def initialize(@request : Request, @response : Response)
      @metadata = {} of String => String
      @attributes = {} of String => Box
    end

    # Get a metadata value
    def [](key : String) : String?
      metadata[key]?
    end

    # Set a metadata value
    def []=(key : String, value : String) : String
      metadata[key] = value
    end

    # Check if context has an error
    def error? : Bool
      !error.nil?
    end

    # Set a typed attribute value for middleware communication
    def set(key : String, value : T) : T forall T
      @attributes[key] = TypedBox.new(value)
      value
    end

    # Get a typed attribute value, returning nil if not found or wrong type
    def get(key : String, target_type : T.class) : T? forall T
      if box = @attributes[key]?
        if typed_box = box.as?(TypedBox(T))
          typed_box.value
        end
      end
    end

    # Get a typed attribute value, raising if not found
    def get!(key : String, target_type : T.class) : T forall T
      get(key, target_type) || raise ArgumentError.new("Missing or invalid context attribute: #{key} (expected #{target_type})")
    end

    # Check if an attribute exists
    def has?(key : String) : Bool
      @attributes.has_key?(key)
    end

    # Remove an attribute
    def delete(key : String) : Box?
      @attributes.delete(key)
    end

    # Set an error and mark response accordingly
    def set_error(err : Exception) : Nil
      @error = err
      response.status = 500
      response.body = {
        "error" => err.message || "Internal server error",
      }
    end

    # Create a context for testing
    def self.background : Context
      req = Request.new(
        service: "test",
        endpoint: "test",
        content_type: "application/json",
        body: nil
      )
      res = Response.new
      new(req, res)
    end
  end

  # Request represents an incoming RPC request
  class Request
    # Service name
    property service : String

    # Endpoint/method name
    property endpoint : String

    # Content type of the request
    property content_type : String

    # Request headers
    property headers : HTTP::Headers

    # Request body (raw bytes or parsed object)
    property body : Bytes | JSON::Any | Nil

    def initialize(
      @service : String,
      @endpoint : String,
      @content_type : String = "application/json",
      @headers : HTTP::Headers = HTTP::Headers.new,
      @body : Bytes | JSON::Any | Nil = nil,
    )
    end

    # Get a header value
    def header(name : String) : String?
      headers[name]?
    end

    # Set a header value
    def header(name : String, value : String) : String
      headers[name] = value
    end
  end

  # Response represents an RPC response
  class Response
    # Response status code
    property status : Int32

    # Response headers
    property headers : HTTP::Headers

    # Response body
    # Allow common JSON-like structures and raw forms for ergonomics
    property body : Bytes | String | JSON::Any | Hash(String, String) | Hash(String, JSON::Any) | Array(JSON::Any) | Nil

    def initialize(
      @status : Int32 = 200,
      @headers : HTTP::Headers = HTTP::Headers.new,
      @body : Bytes | String | JSON::Any | Hash(String, String) | Hash(String, JSON::Any) | Array(JSON::Any) | Nil = nil,
    )
    end

    # Get a header value
    def header(name : String) : String?
      headers[name]?
    end

    # Set a header value
    def header(name : String, value : String) : String
      headers[name] = value
    end

    # Check if response is successful
    def success? : Bool
      status >= 200 && status < 300
    end

    # Check if response is an error
    def error? : Bool
      !success?
    end
  end
end
