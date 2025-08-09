require "json"
require "../../../core/codec"

module Micro::Stdlib::Codecs
  # JSON codec implementation for marshaling/unmarshaling JSON data
  class JSONCodec < Micro::Core::Codec
    # Content type for JSON
    def content_type : String
      "application/json"
    end

    # File extension for JSON files
    def extension : String
      "json"
    end

    # Human-readable name
    def name : String
      "JSON"
    end

    # Marshal an object to JSON bytes
    def marshal(obj : Object) : Bytes
      # If already bytes, return as-is
      return obj if obj.is_a?(Bytes)

      json_string = obj.to_json
      json_string.to_slice
    rescue ex : ::JSON::SerializableError
      raise Micro::Core::CodecError.new(
        "Failed to marshal object to JSON: #{ex.message}",
        Micro::Core::CodecErrorCode::MarshalError,
        content_type
      )
    rescue ex
      raise Micro::Core::CodecError.new(
        "Unexpected error during JSON marshaling: #{ex.message}",
        Micro::Core::CodecErrorCode::MarshalError,
        content_type
      )
    end

    # Unmarshal JSON bytes to a specific type
    def unmarshal(data : Bytes, type : T.class) forall T
      json_string = String.new(data)
      T.from_json(json_string)
    rescue ex : ::JSON::ParseException
      raise Micro::Core::CodecError.new(
        "Failed to parse JSON: #{ex.message}",
        Micro::Core::CodecErrorCode::UnmarshalError,
        content_type
      )
    rescue ex : ::JSON::SerializableError
      raise Micro::Core::CodecError.new(
        "Failed to unmarshal JSON to #{T}: #{ex.message}",
        Micro::Core::CodecErrorCode::TypeMismatch,
        content_type
      )
    rescue ex
      raise Micro::Core::CodecError.new(
        "Unexpected error during JSON unmarshaling: #{ex.message}",
        Micro::Core::CodecErrorCode::UnmarshalError,
        content_type
      )
    end

    # Unmarshal JSON bytes to a specific type, returning nil on error
    def unmarshal?(data : Bytes, type : T.class) forall T
      unmarshal(data, type)
    rescue Micro::Core::CodecError
      nil
    end

    # Check if data looks like JSON
    def self.detect?(data : Bytes) : Bool
      return false if data.empty?

      # Skip whitespace
      start_idx = 0
      while start_idx < data.size && data[start_idx].chr.ascii_whitespace?
        start_idx += 1
      end

      return false if start_idx >= data.size

      # JSON typically starts with { [ " or a digit/true/false/null
      first_char = data[start_idx].chr
      case first_char
      when '{', '[', '"'
        true
      when 't', 'f', 'n', '-'
        true
      when .ascii_number?
        true
      else
        false
      end
    end

    # Validate JSON without parsing to object
    def self.valid?(data : Bytes) : Bool
      json_string = String.new(data)
      ::JSON.parse(json_string)
      true
    rescue
      false
    end

    # Pretty-print JSON data
    def format_pretty(obj : Object) : String
      # First convert to JSON, then parse and pretty print
      json_string = obj.to_json
      parsed = ::JSON.parse(json_string)
      parsed.to_pretty_json(indent: "  ")
    rescue ex
      raise Micro::Core::CodecError.new(
        "Failed to pretty-print JSON: #{ex.message}",
        Micro::Core::CodecErrorCode::MarshalError,
        content_type
      )
    end

    # Minify JSON by removing whitespace
    def minify(data : Bytes) : Bytes
      json_string = String.new(data)
      parsed = ::JSON.parse(json_string)
      parsed.to_json.to_slice
    rescue ex
      raise Micro::Core::CodecError.new(
        "Failed to minify JSON: #{ex.message}",
        Micro::Core::CodecErrorCode::InvalidData,
        content_type
      )
    end
  end

  # Register the JSON codec by default
  class JSONCodec
    def self.register! : Nil
      codec = new
      Micro::Core::CodecRegistry.instance.register(codec)
    end
  end
end

# Auto-register JSON codec when this file is required
Micro::Stdlib::Codecs::JSONCodec.register!
