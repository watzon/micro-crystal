require "../../core/middleware"
require "../../core/context"
require "compress/gzip"
require "compress/deflate"

module Micro::Stdlib::Middleware
  # Automatically compresses responses using gzip or deflate encoding.
  #
  # This middleware reduces bandwidth usage by compressing response bodies
  # when the client supports it. It intelligently decides when to compress
  # based on content type, size, and client capabilities.
  #
  # ## Features
  # - Supports gzip and deflate compression
  # - Configurable minimum size threshold
  # - Selective compression by content type
  # - Respects existing Content-Encoding
  # - Proper Accept-Encoding negotiation
  # - Adds Vary header for correct caching
  #
  # ## Usage
  # ```
  # # Default settings (1KB minimum, common text types)
  # server.use(CompressionMiddleware.new)
  #
  # # Custom configuration
  # server.use(CompressionMiddleware.new(
  #   min_size: 512, # Compress anything over 512 bytes
  #   types: [       # Custom content types
  #   "application/json",
  #   "text/html",
  #   "application/javascript",
  # ],
  #   level: :best_compression # Maximum compression
  # ))
  # ```
  #
  # ## Compression Levels
  # - `:no_compression` - Fastest, no compression
  # - `:best_speed` - Fast compression, lower ratio
  # - `:default` - Balanced speed and compression
  # - `:best_compression` - Slow but best compression
  #
  # ## Content Types
  # By default compresses:
  # - Text formats (HTML, CSS, JavaScript)
  # - JSON and XML
  # - Plain text
  # - YAML
  #
  # ## Performance Considerations
  # - Compression uses CPU cycles
  # - Can increase latency for small responses
  # - Most beneficial for text-based content
  # - Already-compressed formats (JPEG, PNG) gain nothing
  #
  # ## Client Compatibility
  # The middleware checks Accept-Encoding header and only
  # compresses if the client explicitly supports it. Modern
  # browsers always send appropriate Accept-Encoding headers.
  class CompressionMiddleware
    include Micro::Core::Middleware

    # Minimum size for compression (don't compress tiny responses)
    DEFAULT_MIN_SIZE = 1024 # 1KB

    # Content types that should be compressed
    DEFAULT_TYPES = [
      "text/html",
      "text/plain",
      "text/css",
      "text/javascript",
      "application/javascript",
      "application/json",
      "application/xml",
      "text/xml",
      "application/x-yaml",
      "text/yaml",
    ]

    def initialize(
      @min_size = DEFAULT_MIN_SIZE,
      @types : Array(String) = DEFAULT_TYPES,
      @level = Compress::Deflate::DEFAULT_COMPRESSION,
    )
    end

    def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
      # Check if client accepts compression
      accept_encoding = context.request.headers["Accept-Encoding"]?

      # Continue chain first
      next_middleware.try(&.call(context))

      # Only compress if:
      # 1. Client accepts compression
      # 2. Response is successful
      # 3. No Content-Encoding already set
      # 4. Content-Type is compressible
      # 5. Content is large enough

      return unless accept_encoding
      return unless context.response.success?
      return if context.response.headers.has_key?("Content-Encoding")

      content_type = context.response.headers["Content-Type"]?
      return unless content_type && should_compress?(content_type)

      # Get response body as bytes
      body_bytes = response_body_to_bytes(context.response.body)
      return unless body_bytes && body_bytes.size >= @min_size

      # Determine encoding to use
      encoding = select_encoding(accept_encoding)
      return unless encoding

      # Compress the body
      compressed = compress(body_bytes, encoding)

      # Update response
      context.response.body = compressed
      context.response.headers["Content-Encoding"] = encoding
      context.response.headers["Vary"] = add_vary_value(context.response.headers["Vary"]?, "Accept-Encoding")

      # Remove Content-Length as it's no longer accurate
      context.response.headers.delete("Content-Length")
    end

    # Determines if the given content type should be compressed.
    # Checks against the list of compressible content types.
    private def should_compress?(content_type : String) : Bool
      # Extract base content type without charset
      base_type = content_type.split(';').first.strip.downcase
      @types.any? { |type| base_type == type.downcase }
    end

    # Selects the best compression encoding based on client preferences.
    # Parses Accept-Encoding header and chooses highest priority supported encoding.
    private def select_encoding(accept_encoding : String) : String?
      # Parse Accept-Encoding header
      encodings = parse_accept_encoding(accept_encoding)

      # Select best encoding we support
      encodings.each do |encoding, quality|
        case encoding.downcase
        when "gzip", "x-gzip"
          return "gzip" if quality > 0
        when "deflate"
          return "deflate" if quality > 0
        when "*"
          return "gzip" if quality > 0 # Default to gzip for wildcard
        end
      end

      nil
    end

    # Parses the Accept-Encoding header into encoding/quality pairs.
    # Returns an array of tuples sorted by quality value (highest first).
    private def parse_accept_encoding(header : String) : Array(Tuple(String, Float32))
      encodings = [] of Tuple(String, Float32)

      header.split(',').each do |part|
        parts = part.strip.split(';')
        encoding = parts[0].strip

        # Parse quality value
        quality = 1.0_f32
        if parts.size > 1
          q_part = parts[1].strip
          if q_part.starts_with?("q=")
            quality = q_part[2..].to_f32? || 0.0_f32
          end
        end

        encodings << {encoding, quality}
      end

      # Sort by quality (highest first)
      encodings.sort_by { |_, q| -q }
    end

    # Compresses data using the specified encoding algorithm.
    # Supports gzip, deflate, and brotli compression.
    private def compress(data : Bytes, encoding : String) : Bytes
      io = IO::Memory.new

      case encoding
      when "gzip"
        Compress::Gzip::Writer.open(io, level: @level) do |gzip|
          gzip.write(data)
        end
      when "deflate"
        Compress::Deflate::Writer.open(io, level: @level) do |deflate|
          deflate.write(data)
        end
      else
        return data # Unsupported encoding, return original
      end

      io.to_slice
    end

    # Converts various response body types to bytes for compression.
    # Handles Bytes, JSON::Any, Hash, and nil values.
    private def response_body_to_bytes(body : Bytes | String | JSON::Any | Hash(String, String) | Hash(String, JSON::Any) | Array(JSON::Any) | Nil) : Bytes?
      case body
      when Bytes
        body
      when JSON::Any
        body.to_json.to_slice
      when String
        body.to_slice
      when Hash(String, JSON::Any)
        body.to_json.to_slice
      when Array(JSON::Any)
        body.to_json.to_slice
      when Hash
        body.to_json.to_slice
      when Nil
        nil
      else
        body.to_s.to_slice
      end
    end

    private def add_vary_value(existing : String?, value : String) : String
      if existing
        values = existing.split(',').map(&.strip)
        values << value unless values.includes?(value)
        values.join(", ")
      else
        value
      end
    end
  end
end
