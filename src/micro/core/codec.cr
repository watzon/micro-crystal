module Micro::Core
  # Codec handles marshaling and unmarshaling of data for transport
  # It provides an abstraction layer for different serialization formats (JSON, MessagePack, Protobuf, etc.)
  abstract class Codec
    # Content type this codec handles (e.g., "application/json", "application/protobuf")
    abstract def content_type : String

    # Marshal an object to bytes
    abstract def marshal(obj : Object) : Bytes

    # Unmarshal bytes to a specific type
    abstract def unmarshal(data : Bytes, type : T.class) forall T

    # Unmarshal bytes to a specific type, returning nil on error
    abstract def unmarshal?(data : Bytes, type : T.class) forall T

    # Check if this codec can handle the given content type
    def handles?(content_type : String) : Bool
      self.content_type == content_type
    end

    # Get the file extension associated with this codec
    abstract def extension : String

    # Get human-readable name of the codec
    abstract def name : String
  end

  # Registry for codec implementations
  class CodecRegistry
    # Global registry instance
    @@instance : CodecRegistry?

    # Get the global registry instance
    def self.instance : CodecRegistry
      @@instance ||= new
    end

    @codecs = {} of String => Codec

    # Register a codec for a content type
    def register(codec : Codec) : Nil
      @codecs[codec.content_type] = codec
    end

    # Get a codec by content type
    def get(content_type : String) : Codec?
      @codecs[content_type]?
    end

    # Get a codec by content type, raise if not found
    def get!(content_type : String) : Codec
      @codecs[content_type]? || raise CodecError.new("No codec registered for content type: #{content_type}")
    end

    # List all registered content types
    def content_types : Array(String)
      @codecs.keys
    end

    # List all registered codecs
    def codecs : Array(Codec)
      @codecs.values
    end

    # Check if a content type has a registered codec
    def has?(content_type : String) : Bool
      @codecs.has_key?(content_type)
    end

    # Remove a codec by content type
    def unregister(content_type : String) : Codec?
      @codecs.delete(content_type)
    end

    # Clear all registered codecs
    def clear : Nil
      @codecs.clear
    end

    # Get default codec (first registered, typically JSON)
    def default : Codec?
      @codecs.values.first?
    end

    # Get default codec, raise if none registered
    def default! : Codec
      default || raise CodecError.new("No default codec available - no codecs registered")
    end

    # Static helper methods

    # Register a codec to the global registry
    def self.register(codec : Codec) : Nil
      instance.register(codec)
    end

    # Get a codec from the global registry
    def self.get(content_type : String) : Codec?
      instance.get(content_type)
    end

    # Get a codec from the global registry, raise if not found
    def self.get!(content_type : String) : Codec
      instance.get!(content_type)
    end
  end

  # Helper methods for codec operations
  module CodecHelpers
    # Marshal an object using the appropriate codec
    def self.marshal(obj : Object, content_type : String? = nil) : Bytes
      codec = if content_type
                CodecRegistry.instance.get!(content_type)
              else
                CodecRegistry.instance.default!
              end
      codec.marshal(obj)
    end

    # Unmarshal bytes to a specific type using the appropriate codec
    def self.unmarshal(data : Bytes, type : T.class, content_type : String? = nil) forall T
      codec = if content_type
                CodecRegistry.instance.get!(content_type)
              else
                CodecRegistry.instance.default!
              end
      codec.unmarshal(data, type)
    end

    # Unmarshal bytes to a specific type, returning nil on error
    def self.unmarshal?(data : Bytes, type : T.class, content_type : String? = nil) forall T
      codec = if content_type
                CodecRegistry.instance.get!(content_type)
              else
                CodecRegistry.instance.default!
              end
      codec.unmarshal?(data, type)
    end

    # Get content type for an object (uses default codec)
    def self.content_type_for(obj : Object) : String
      CodecRegistry.instance.default!.content_type
    end

    # Auto-detect content type from data (basic heuristics)
    def self.detect_content_type(data : Bytes) : String?
      return nil if data.empty?

      # Try to detect JSON
      if data[0] == 0x7B_u8 || data[0] == 0x5B_u8 # { or [
        return "application/json"
      end

      # Try to detect MessagePack (first byte often 0x80-0x9F for fixmap/fixarray)
      if data[0] >= 0x80_u8 && data[0] <= 0x9F_u8
        return "application/msgpack"
      end

      # Default to the registry's default codec
      CodecRegistry.instance.default.try(&.content_type)
    end
  end

  # Codec-specific errors
  class CodecError < Exception
    # Error code for different codec operations
    getter code : CodecErrorCode

    # The content type that caused the error
    getter content_type : String?

    def initialize(message : String, @code : CodecErrorCode = CodecErrorCode::Unknown, @content_type : String? = nil)
      super(message)
    end

    def initialize(message : String, @content_type : String)
      @code = CodecErrorCode::Unknown
      super(message)
    end
  end

  # Codec error codes
  enum CodecErrorCode
    Unknown
    NotRegistered
    MarshalError
    UnmarshalError
    InvalidData
    TypeMismatch
    UnsupportedType
  end

  # Convenience method to get the global codec selector
  def self.selector : CodecSelector
    CodecSelector.instance
  end

  # Message wrapper for codec operations that includes metadata
  struct CodecMessage(T)
    # The actual data
    property data : T

    # Content type used for encoding/decoding
    property content_type : String

    # Additional metadata
    property metadata : Hash(String, String)

    def initialize(@data : T, @content_type : String, @metadata : Hash(String, String) = {} of String => String)
    end

    # Marshal this message to bytes
    def to_bytes : Bytes
      CodecHelpers.marshal(data, content_type)
    end

    # Create a CodecMessage from bytes
    def self.from_bytes(data : Bytes, type : U.class, content_type : String) forall U
      obj = CodecHelpers.unmarshal(data, type, content_type)
      new(obj, content_type)
    end

    # Create a CodecMessage from bytes with auto-detection
    def self.from_bytes(data : Bytes, type : U.class) forall U
      detected_type = CodecHelpers.detect_content_type(data)
      raise CodecError.new("Could not detect content type") unless detected_type

      obj = CodecHelpers.unmarshal(data, type, detected_type)
      new(obj, detected_type)
    end
  end
end
