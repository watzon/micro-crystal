require "./codec"

module Micro::Core
  # CodecSelector handles content-type negotiation and codec selection
  # It supports Accept header parsing, quality value preferences, and fallback strategies
  class CodecSelector
    # Default codec to use when no match is found
    property default_codec : Codec?

    # Registry to use for codec lookup
    property registry : CodecRegistry

    def initialize(@registry : CodecRegistry = CodecRegistry.instance, @default_codec : Codec? = nil)
    end

    # Select codec based on content-type header
    def select_by_content_type(content_type : String?) : Codec
      return default_codec! if content_type.nil? || content_type.empty?

      # Parse content type, ignoring charset and other parameters
      base_type = parse_base_content_type(content_type)

      # Try exact match first
      if codec = @registry.get(base_type)
        return codec
      end

      # Try aliases and wildcards
      case base_type
      when "application/x-msgpack", "msgpack", "application/vnd.msgpack"
        @registry.get("application/msgpack") || default_codec!
      when "application/x-json", "text/json"
        @registry.get("application/json") || default_codec!
      when "*/*", "application/*"
        default_codec!
      else
        default_codec!
      end
    end

    # Select codec based on Accept header with quality values
    def select_by_accept(accept_header : String?) : Codec
      return default_codec! if accept_header.nil? || accept_header.empty?

      # Parse Accept header into ordered list of preferences
      preferences = parse_accept_header(accept_header)

      # Try each preference in order
      preferences.each do |pref|
        # Check if we have a codec for this content type
        if codec = select_by_content_type(pref.content_type)
          return codec if codec != default_codec || pref.content_type == "*/*"
        end
      end

      # No matches found
      default_codec!
    end

    # Negotiate codec based on request Accept and response Content-Type
    def negotiate(accept : String?, content_type : String?) : Codec
      # If content-type is specified, respect it
      if content_type && !content_type.empty?
        return select_by_content_type(content_type)
      end

      # Otherwise, use Accept header
      select_by_accept(accept)
    end

    # Auto-detect codec from data bytes
    def detect_from_data(data : Bytes) : Codec?
      return nil if data.empty?

      # Check JSON codec first (most common)
      if json_codec = @registry.get("application/json")
        if json_codec.class.responds_to?(:detect?) && Micro::Stdlib::Codecs::JSONCodec.detect?(data)
          return json_codec
        end
      end

      # Check MsgPack codec
      if msgpack_codec = @registry.get("application/msgpack")
        # Use type-specific check for MsgPack detection
        if data.size > 0 && (data[0] == 0xdc_u8 || data[0] == 0xdd_u8 ||
           data[0] == 0xde_u8 || data[0] == 0xdf_u8 ||
           (data[0] >= 0x80_u8 && data[0] <= 0x8f_u8) ||
           (data[0] >= 0x90_u8 && data[0] <= 0x9f_u8))
          return msgpack_codec
        end
      end

      nil
    end

    # Select codec with fallback chain: content-type -> accept -> detect -> default
    def select_with_fallback(content_type : String?, accept : String?, data : Bytes? = nil) : Codec
      # Try content-type first
      if content_type && !content_type.empty?
        if codec = select_by_content_type(content_type)
          return codec if codec != default_codec
        end
      end

      # Try accept header
      if accept && !accept.empty?
        if codec = select_by_accept(accept)
          return codec if codec != default_codec
        end
      end

      # Try detection from data
      if data && !data.empty?
        if codec = detect_from_data(data)
          return codec
        end
      end

      # Fall back to default
      default_codec!
    end

    private def default_codec! : Codec
      @default_codec || @registry.default!
    end

    private def parse_base_content_type(content_type : String) : String
      # Extract base content type, removing parameters like charset
      parts = content_type.split(';', limit: 2)
      parts.first.strip.downcase
    end

    # Represents a content type preference with quality value
    struct AcceptPreference
      getter content_type : String
      getter quality : Float32
      getter params : Hash(String, String)

      def initialize(@content_type : String, @quality : Float32 = 1.0, @params : Hash(String, String) = {} of String => String)
      end

      # Compare preferences by quality (higher is better)
      def <=>(other : AcceptPreference) : Int32
        # Compare quality values (higher is better, so reverse order)
        if other.quality > @quality
          1
        elsif other.quality < @quality
          -1
        else
          0
        end
      end
    end

    private def parse_accept_header(accept : String) : Array(AcceptPreference)
      preferences = [] of AcceptPreference

      # Split by comma to get individual media types
      accept.split(',').each do |media_range|
        media_range = media_range.strip
        next if media_range.empty?

        # Split by semicolon to separate type from parameters
        parts = media_range.split(';').map(&.strip)
        content_type = parts.first.downcase

        # Parse parameters (q value and others)
        quality = 1.0_f32
        params = {} of String => String

        parts[1..-1].each do |param|
          key_value = param.split('=', limit: 2)
          next unless key_value.size == 2

          key = key_value[0].strip.downcase
          value = key_value[1].strip.delete('"')

          if key == "q"
            quality = value.to_f32? || 1.0_f32
          else
            params[key] = value
          end
        end

        preferences << AcceptPreference.new(content_type, quality, params)
      end

      # Sort by quality value (descending)
      preferences.sort!
    end
  end

  # Global codec selector instance
  class CodecSelector
    @@instance : CodecSelector?

    def self.instance : CodecSelector
      @@instance ||= new
    end

    def self.reset_instance : Nil
      @@instance = nil
    end
  end
end
