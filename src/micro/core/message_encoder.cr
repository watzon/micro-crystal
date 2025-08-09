require "json"

module Micro::Core
  # Shared module for message encoding/decoding operations
  # Provides consistent patterns for marshaling/unmarshaling data
  module MessageEncoder
    extend self

    # Marshal an object to bytes using the specified codec
    # Falls back to JSON if no codec is specified
    def marshal(obj : Object, codec : Codec? = nil, content_type : String? = nil) : Bytes
      if codec
        codec.marshal(obj)
      elsif content_type
        CodecRegistry.marshal(obj, content_type)
      else
        # Default to JSON
        obj.to_json.to_slice
      end
    end

    # Unmarshal bytes to a specific type using the specified codec
    # Falls back to JSON if no codec is specified
    def unmarshal(data : Bytes, type : T.class, codec : Codec? = nil, content_type : String? = nil) forall T
      return nil if data.empty?

      if codec
        codec.unmarshal(data, type)
      elsif content_type
        CodecRegistry.unmarshal(data, type, content_type)
      else
        # Default to JSON
        T.from_json(String.new(data))
      end
    end

    # Safely unmarshal with error handling
    def unmarshal?(data : Bytes, type : T.class, codec : Codec? = nil, content_type : String? = nil) forall T
      return nil if data.empty?

      unmarshal(data, type, codec, content_type)
    rescue
      nil
    end

    # Convert various types to bytes
    def to_bytes(obj : Object | String | Bytes | Nil) : Bytes
      case obj
      when Bytes
        obj
      when String
        obj.to_slice
      when Nil
        Bytes.empty
      else
        obj.to_json.to_slice
      end
    end

    # Create error response bytes
    def error_bytes(message : String, codec : Codec? = nil, content_type : String? = nil) : Bytes
      error_obj = {"error" => message}
      marshal(error_obj, codec, content_type)
    end

    # Create error response with status
    def error_response(message : String, status : Int32 = 500, codec : Codec? = nil, content_type : String? = nil) : NamedTuple(body: Bytes, status: Int32, content_type: String)
      error_obj = {"error" => message}
      body = marshal(error_obj, codec, content_type)

      actual_content_type = if codec
                              codec.content_type
                            elsif content_type
                              content_type
                            else
                              "application/json"
                            end

      {body: body, status: status, content_type: actual_content_type}
    end

    # Convert context response body to bytes
    def response_body_to_bytes(body : Object | String | Bytes | Hash | Array | JSON::Any | Nil, codec : Codec? = nil) : Bytes
      case body
      when Bytes
        body
      when String
        body.to_slice
      when Nil
        Bytes.empty
      when JSON::Any
        body.to_json.to_slice
      when Hash, Array
        if codec
          codec.marshal(body)
        else
          body.to_json.to_slice
        end
      else
        if codec
          codec.marshal(body)
        else
          body.to_s.to_slice
        end
      end
    end

    # Detect codec from content type or Accept header
    def detect_codec(content_type : String?, accept_header : String? = nil) : Codec?
      # Try content type first
      if content_type
        codec = CodecRegistry.get(content_type)
        return codec if codec
      end

      # Try accept header
      if accept_header && accept_header != "*/*"
        # Simple parsing - just take the first type
        first_type = accept_header.split(',').first.strip
        codec = CodecRegistry.get(first_type)
        return codec if codec
      end

      # Default to JSON codec if registered
      CodecRegistry.get("application/json")
    end
  end
end
