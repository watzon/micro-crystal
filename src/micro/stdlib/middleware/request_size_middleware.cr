require "../../core/middleware"
require "../../core/context"

module Micro::Stdlib::Middleware
  # Middleware that limits the size of incoming requests to prevent DoS attacks.
  #
  # This middleware protects against memory exhaustion and processing overhead
  # from excessively large requests. It checks the Content-Length header and
  # optionally tracks the actual body size during reading.
  #
  # ## Features
  # - Content-Length header validation
  # - Actual body size tracking
  # - Per-endpoint size limits
  # - Configurable response messages
  # - Exemption patterns for specific paths
  #
  # ## Usage
  # ```
  # # Basic usage with 1MB limit
  # middleware = RequestSizeMiddleware.new(
  #   max_size: 1.megabyte
  # )
  #
  # # With custom limits per endpoint
  # middleware = RequestSizeMiddleware.new(
  #   max_size: 1.megabyte,
  #   endpoint_limits: {
  #     "/api/upload" => 100.megabytes,
  #     "/api/avatar" => 5.megabytes,
  #   }
  # )
  #
  # # With exemptions
  # middleware = RequestSizeMiddleware.new(
  #   max_size: 1.megabyte,
  #   exempt_paths: ["/health", "/metrics"]
  # )
  #
  # server.use(middleware)
  # ```
  #
  # ## Security Considerations
  # - Set reasonable limits based on your application's needs
  # - Consider different limits for authenticated vs anonymous users
  # - Monitor for patterns of size-based attacks
  # - Log violations for security analysis
  class RequestSizeMiddleware
    include Micro::Core::Middleware

    # Configuration for size limits
    record Config,
      # Default maximum request size in bytes
      max_size : ::Int64 = 1_048_576_i64, # 1MB default
      # Per-endpoint size limits (path => size)
      endpoint_limits : Hash(String, ::Int64) = {} of String => ::Int64,
      # Paths exempt from size limits
      exempt_paths : Array(String) = [] of String,
      # Whether to check Content-Length header
      check_content_length : Bool = true,
      # Whether to track actual body size (more overhead)
      track_body_size : Bool = false,
      # Custom error message
      error_message : String? = nil,
      # Whether to include size info in error
      include_size_info : Bool = true

    def initialize(
      max_size = 1_048_576_i64,
      endpoint_limits : Hash(String, ::Int32 | ::Int64) = {} of String => (::Int32 | ::Int64),
      exempt_paths : Array(String) = [] of String,
      check_content_length = true,
      track_body_size = false,
      error_message : String? = nil,
      include_size_info = true,
    )
      # Convert all sizes to Int64
      converted_limits = {} of String => ::Int64
      endpoint_limits.each do |path, size|
        converted_limits[path] = size.is_a?(::Int32) ? size.to_i64 : size.as(::Int64)
      end

      @config = Config.new(
        max_size: max_size,
        endpoint_limits: converted_limits,
        exempt_paths: exempt_paths,
        check_content_length: check_content_length,
        track_body_size: track_body_size,
        error_message: error_message,
        include_size_info: include_size_info
      )
    end

    def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
      # Check if path is exempt
      path = context.request.headers["Path"]? || "/"
      if @config.exempt_paths.includes?(path)
        next_middleware.try(&.call(context))
        return
      end

      # Get the appropriate size limit for this endpoint
      size_limit = @config.endpoint_limits[path]? || @config.max_size

      # Check Content-Length header if configured
      if @config.check_content_length
        if content_length_str = context.request.headers["Content-Length"]?
          begin
            content_length = content_length_str.to_i64

            if content_length > size_limit
              handle_size_exceeded(context, content_length, size_limit)
              return
            end
          rescue ArgumentError
            # Invalid Content-Length header
            handle_invalid_content_length(context)
            return
          end
        end
      end

      # If tracking body size, check the actual body size
      if @config.track_body_size && (body = context.request.body)
        # Check actual body size
        actual_size = case body
                      when Bytes
                        body.size.to_i64
                      when JSON::Any
                        body.to_json.bytesize.to_i64
                      else
                        0_i64
                      end

        if actual_size > size_limit
          handle_size_exceeded(context, actual_size, size_limit)
          return
        end
      end

      # Continue to next middleware
      next_middleware.try(&.call(context))
    end

    private def handle_size_exceeded(
      context : Micro::Core::Context,
      actual_size : ::Int64,
      limit : ::Int64,
    ) : Nil
      context.response.status = 413 # Payload Too Large

      error_msg = @config.error_message || "Request size exceeds limit"

      response_body = if @config.include_size_info
                        {
                          "error"       => error_msg,
                          "size"        => actual_size.to_s,
                          "limit"       => limit.to_s,
                          "exceeded_by" => (actual_size - limit).to_s,
                        }
                      else
                        {
                          "error" => error_msg,
                        }
                      end

      context.response.body = response_body
      context.response.headers["Connection"] = "close"
    end

    private def handle_invalid_content_length(context : Micro::Core::Context) : Nil
      context.response.status = 400
      context.response.body = {
        "error" => "Invalid Content-Length header",
      }
    end

    # Helper class that tracks the size of data read from a body
    private class SizeTrackingBody < IO
      @wrapped : Pointer(Void)
      @limit : ::Int64
      @exceeded_callback : ::Int64 ->
      @bytes_read : ::Int64
      @limit_exceeded : Bool

      def initialize(
        wrapped : IO,
        @limit : ::Int64,
        &@exceeded_callback : ::Int64 ->
      )
        @wrapped = Box.box(wrapped)
        @bytes_read = 0_i64
        @limit_exceeded = false
      end

      def read(slice : Bytes) : ::Int32
        return 0 if @limit_exceeded

        # Delegate to wrapped body
        io = Box(IO).unbox(@wrapped)
        bytes = if io.responds_to?(:read)
                  io.read(slice)
                else
                  0
                end

        @bytes_read += bytes

        if @bytes_read > @limit && !@limit_exceeded
          @limit_exceeded = true
          @exceeded_callback.call(@bytes_read)
        end

        bytes
      end

      def write(slice : Bytes) : Nil
        raise IO::Error.new("Cannot write to request body")
      end

      # Delegate other methods to wrapped body
      macro method_missing(call)
        Box(IO).unbox(@wrapped).{{call}}
      end
    end
  end

  # Convenience helper for size units
  struct Int32
    def kilobytes : Int64
      self.to_i64 * 1024_i64
    end

    def megabytes : Int64
      self.to_i64 * 1024_i64 * 1024_i64
    end

    def gigabytes : Int64
      self.to_i64 * 1024_i64 * 1024_i64 * 1024_i64
    end
  end

  struct Int64
    def kilobytes : Int64
      self * 1024_i64
    end

    def megabytes : Int64
      self * 1024_i64 * 1024_i64
    end

    def gigabytes : Int64
      self * 1024_i64 * 1024_i64 * 1024_i64
    end
  end
end
