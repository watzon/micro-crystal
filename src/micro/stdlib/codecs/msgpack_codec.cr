require "msgpack"
require "json"
require "base64"
require "../../core/codec"

module Micro::Stdlib::Codecs
  # MsgPackCodec implements the Codec interface for MessagePack binary serialization.
  # MessagePack is more compact than JSON and preserves type information better.
  class MsgPackCodec < Micro::Core::Codec
    CONTENT_TYPE = "application/msgpack"
    ALIASES      = ["msgpack", "application/x-msgpack", "application/vnd.msgpack"]

    # Content type for MessagePack
    def content_type : String
      CONTENT_TYPE
    end

    # File extension for MessagePack files
    def extension : String
      "msgpack"
    end

    # Human-readable name
    def name : String
      "MessagePack"
    end

    # Marshal an object to MessagePack bytes
    def marshal(obj : Object) : Bytes
      case obj
      when ::JSON::Any
        # Special handling for JSON::Any
        convert_json_any_to_msgpack(obj.as(::JSON::Any))
      when Nil, Bool, String, Symbol, Number
        # Basic types can be marshaled directly
        obj.to_msgpack
      when Array
        # Arrays can be marshaled if their elements are marshalable
        obj.to_msgpack
      when Hash
        # Hashes can be marshaled if keys and values are marshalable
        obj.to_msgpack
      when Tuple
        # Tuples can be marshaled
        obj.to_msgpack
      when .responds_to?(:to_msgpack)
        # Objects that explicitly support MessagePack
        obj.to_msgpack
      else
        # For other objects, try to convert to a hash representation
        raise Micro::Core::CodecError.new(
          "Cannot marshal #{obj.class} to MsgPack: type not supported",
          Micro::Core::CodecErrorCode::UnsupportedType,
          content_type
        )
      end
    rescue ex : Micro::Core::CodecError
      raise ex
    rescue ex : Exception
      raise Micro::Core::CodecError.new(
        "Failed to marshal object to MsgPack: #{ex.message}",
        Micro::Core::CodecErrorCode::MarshalError,
        content_type
      )
    end

    # Convert JSON::Any to MessagePack bytes
    private def convert_json_any_to_msgpack(json : ::JSON::Any) : Bytes
      case json.raw
      when Nil
        nil.to_msgpack
      when Bool
        json.as_bool.to_msgpack
      when Int64
        json.as_i64.to_msgpack
      when Float64
        json.as_f.to_msgpack
      when String
        json.as_s.to_msgpack
      when Array(::JSON::Any)
        arr = json.as_a.map { |v| convert_json_any_to_native(v) }
        arr.to_msgpack
      when Hash(String, ::JSON::Any)
        hash = {} of String => MsgPackValue
        json.as_h.each { |k, v| hash[k] = convert_json_any_to_native(v) }
        hash.to_msgpack
      else
        raise Micro::Core::CodecError.new(
          "Unexpected JSON::Any raw type: #{json.raw.class}",
          Micro::Core::CodecErrorCode::UnsupportedType,
          content_type
        )
      end
    end

    # Type alias for MessagePack-compatible values
    alias MsgPackValue = Nil | Bool | String | Int64 | Float64 | Array(MsgPackValue) | Hash(String, MsgPackValue)

    # Convert JSON::Any to native Crystal types for msgpack serialization
    private def convert_json_any_to_native(json : ::JSON::Any) : MsgPackValue
      case json.raw
      when Nil
        nil
      when Bool
        json.as_bool
      when Int64
        json.as_i64
      when Float64
        json.as_f
      when String
        json.as_s
      when Array(::JSON::Any)
        json.as_a.map { |v| convert_json_any_to_native(v).as(MsgPackValue) }
      when Hash(String, ::JSON::Any)
        hash = {} of String => MsgPackValue
        json.as_h.each { |k, v| hash[k] = convert_json_any_to_native(v) }
        hash
      else
        # Fallback to string representation for unknown types
        json.raw.to_s
      end
    end

    # Unmarshal MessagePack bytes to a specific type
    def unmarshal(data : Bytes, type : T.class) forall T
      # Special handling for JSON::Any
      {% if T == ::JSON::Any %}
        # Convert MessagePack to JSON::Any via intermediate type
        msgpack_any = MessagePack::Any.from_msgpack(data)
        convert_msgpack_to_json_any(msgpack_any)
      {% elsif T == MessagePack::Any %}
        # Direct MessagePack::Any deserialization
        MessagePack::Any.from_msgpack(data)
      {% elsif T == String || T == Bool || T == Nil ||
                 T == Int8 || T == Int16 || T == Int32 || T == Int64 ||
                 T == UInt8 || T == UInt16 || T == UInt32 || T == UInt64 ||
                 T == Float32 || T == Float64 %}
        # Basic types use unpacker directly
        unpacker = MessagePack::IOUnpacker.new(data)
        T.new(unpacker)
      {% elsif T < Array %}
        # Arrays need special handling
        unpacker = MessagePack::IOUnpacker.new(data)
        T.new(unpacker)
      {% elsif T < Hash %}
        # Hashes need special handling
        unpacker = MessagePack::IOUnpacker.new(data)
        T.new(unpacker)
      {% else %}
        # For other types, check if they have from_msgpack or MessagePack::Serializable
        {% if T.has_method?(:from_msgpack) %}
          type.from_msgpack(data)
        {% else %}
          # Try using unpacker constructor
          unpacker = MessagePack::IOUnpacker.new(data)
          T.new(unpacker)
        {% end %}
      {% end %}
    rescue ex : MessagePack::UnpackError
      raise Micro::Core::CodecError.new(
        "Failed to parse MsgPack: #{ex.message}",
        Micro::Core::CodecErrorCode::UnmarshalError,
        content_type
      )
    rescue ex : MessagePack::TypeCastError
      # Type mismatch - the msgpack data doesn't match expected type
      raise Micro::Core::CodecError.new(
        "Type mismatch: cannot unmarshal MsgPack data to #{T}",
        Micro::Core::CodecErrorCode::TypeMismatch,
        content_type
      )
    rescue ex : Exception
      raise Micro::Core::CodecError.new(
        "Failed to unmarshal MsgPack to #{T}: #{ex.message}",
        Micro::Core::CodecErrorCode::UnmarshalError,
        content_type
      )
    end

    # Convert MessagePack::Any to JSON::Any
    private def convert_msgpack_to_json_any(msgpack : MessagePack::Any) : ::JSON::Any
      case msgpack.raw
      when Nil
        ::JSON::Any.new(nil)
      when Bool
        ::JSON::Any.new(msgpack.raw.as(Bool))
      when String
        ::JSON::Any.new(msgpack.raw.as(String))
      when Int8, Int16, Int32, Int64
        ::JSON::Any.new(msgpack.raw.as(Int).to_i64)
      when UInt8, UInt16, UInt32, UInt64
        ::JSON::Any.new(msgpack.raw.as(Int).to_i64)
      when Float32, Float64
        ::JSON::Any.new(msgpack.raw.as(Float).to_f64)
      when Array
        arr = msgpack.raw.as(Array).map { |v| convert_msgpack_to_json_any(MessagePack::Any.new(v)) }
        ::JSON::Any.new(arr)
      when Hash
        hash = {} of String => ::JSON::Any
        msgpack.raw.as(Hash).each do |k, v|
          hash[k.to_s] = convert_msgpack_to_json_any(MessagePack::Any.new(v))
        end
        ::JSON::Any.new(hash)
      when Bytes
        # Convert bytes to base64 string for JSON compatibility
        ::JSON::Any.new(Base64.encode(msgpack.raw.as(Bytes)))
      else
        # Fallback to string representation
        ::JSON::Any.new(msgpack.raw.to_s)
      end
    end

    # Unmarshal MessagePack bytes to a specific type, returning nil on error
    def unmarshal?(data : Bytes, type : T.class) forall T
      unmarshal(data, type)
    rescue Micro::Core::CodecError
      nil
    end

    # Check if data looks like MessagePack
    def self.detect?(data : Bytes) : Bool
      return false if data.empty?

      # MessagePack format detection based on first byte
      # See: https://github.com/msgpack/msgpack/blob/master/spec.md
      first_byte = data[0]

      # Check for obvious JSON first
      # But 0x7b (123) is also a valid positive fixint in MessagePack!
      # We need a better heuristic - check if it looks like JSON
      if (first_byte == 0x7b || first_byte == 0x5b) && data.size > 1
        # If it starts with { or [ and has more data, check if next char is JSON-like
        second_byte = data[1]
        # In JSON, after { or [ we often see whitespace, quotes, or another bracket
        if second_byte == 0x20 || second_byte == 0x09 || second_byte == 0x0a ||                     # space, tab, newline
           second_byte == 0x0d || second_byte == 0x22 ||                                            # carriage return, quote
           second_byte == 0x7b || second_byte == 0x5b || second_byte == 0x7d || second_byte == 0x5d # brackets
          return false
        end
      end

      case first_byte
      when 0x00..0x7f # positive fixint
        true
      when 0x80..0x8f # fixmap
        true
      when 0x90..0x9f # fixarray
        true
      when 0xa0..0xbf # fixstr
        true
      when 0xc0 # nil
        true
      when 0xc1 # reserved/unused in msgpack spec
        false
      when 0xc2, 0xc3 # false, true
        true
      when 0xc4..0xd3 # bin/ext/float/int types
        true
      when 0xd4..0xd8 # fixext types
        true
      when 0xd9..0xdb # str types
        true
      when 0xdc..0xdd # array types
        true
      when 0xde..0xdf # map types
        true
      when 0xe0..0xff # negative fixint
        true
      else
        false
      end
    end

    # Validate MessagePack without parsing to object
    def self.valid?(data : Bytes) : Bool
      # Try to unpack as MessagePack::Any to validate structure
      MessagePack::Any.from_msgpack(data)
      true
    rescue
      false
    end

    # Pretty-print MessagePack data (convert to JSON for readability)
    def format_pretty(obj : Object) : String
      # Since MessagePack is binary, we'll convert to JSON for pretty printing
      # This is a simple approach: serialize to msgpack, deserialize, then to JSON
      case obj
      when Hash, Array
        # For collections, convert to JSON directly for pretty printing
        obj.to_pretty_json(indent: "  ")
      when .responds_to?(:to_json)
        # For objects that can be converted to JSON
        obj.to_json
      else
        # For other types, convert to string
        obj.to_s
      end
    rescue ex
      raise Micro::Core::CodecError.new(
        "Failed to pretty-print MsgPack: #{ex.message}",
        Micro::Core::CodecErrorCode::MarshalError,
        content_type
      )
    end

    # Get size of MessagePack data
    def self.size(data : Bytes) : Int32
      data.size
    end
  end

  # Register the MsgPack codec
  class MsgPackCodec
    def self.register! : Nil
      codec = new
      registry = Micro::Core::CodecRegistry.instance

      # Register with main content type
      registry.register(codec)

      # Also register with aliases for compatibility
      ALIASES.each do |alias_type|
        # Create wrapper codec for each alias
        wrapper = MsgPackAliasCodec.new(codec, alias_type)
        registry.register(wrapper)
      end
    end
  end

  # Wrapper codec for aliases
  private class MsgPackAliasCodec < Micro::Core::Codec
    def initialize(@codec : MsgPackCodec, @alias_content_type : String)
    end

    def content_type : String
      @alias_content_type
    end

    def extension : String
      @codec.extension
    end

    def name : String
      @codec.name
    end

    def marshal(obj : Object) : Bytes
      @codec.marshal(obj)
    end

    def unmarshal(data : Bytes, type : T.class) forall T
      @codec.unmarshal(data, type)
    end

    def unmarshal?(data : Bytes, type : T.class) forall T
      @codec.unmarshal?(data, type)
    end
  end
end

# Auto-register MsgPack codec when this file is required
# NOTE: Commented out auto-registration to prevent conflicts with JSON-only types
# Micro::Stdlib::Codecs::MsgPackCodec.register!
