require "../../core/middleware"
require "../../core/context"

module Micro::Stdlib::Middleware
  # Handles Cross-Origin Resource Sharing (CORS) for web browser clients.
  #
  # This middleware implements the CORS protocol, allowing web applications
  # from different domains to access your API. It handles both simple requests
  # and preflight OPTIONS requests according to the W3C CORS specification.
  #
  # ## Features
  # - Configurable allowed origins, methods, and headers
  # - Automatic preflight request handling
  # - Support for credentials (cookies, auth headers)
  # - Customizable max age for preflight caching
  # - Exposed headers configuration
  # - Wildcard origin support (use with caution)
  #
  # ## Usage
  # ```
  # # Allow all origins (not recommended for production)
  # server.use(CORSMiddleware.new)
  #
  # # Specific origins only
  # server.use(CORSMiddleware.new(
  #   allowed_origins: ["https://app.example.com", "https://admin.example.com"],
  #   allowed_methods: ["GET", "POST", "PUT", "DELETE"],
  #   allowed_headers: ["Content-Type", "Authorization"],
  #   exposed_headers: ["X-Total-Count", "X-Page-Number"],
  #   max_age: 3600, # 1 hour
  #   allow_credentials: true
  # ))
  # ```
  #
  # ## Security Considerations
  # - Never use wildcard ("*") origins with credentials
  # - Be specific about allowed origins in production
  # - Limit exposed headers to necessary ones only
  # - Consider origin validation beyond simple string matching
  #
  # ## Preflight Requests
  # Browsers send OPTIONS requests before certain cross-origin requests.
  # This middleware automatically handles these with appropriate headers.
  #
  # ## Headers Set
  # - `Access-Control-Allow-Origin`
  # - `Access-Control-Allow-Methods` (preflight only)
  # - `Access-Control-Allow-Headers` (preflight only)
  # - `Access-Control-Allow-Credentials` (if enabled)
  # - `Access-Control-Expose-Headers` (if configured)
  # - `Access-Control-Max-Age` (preflight only)
  # - `Vary: Origin` (for proper caching)
  class CORSMiddleware
    include Micro::Core::Middleware

    def initialize(
      @allowed_origins : Array(String) = ["*"],
      @allowed_methods : Array(String) = ["GET", "POST", "PUT", "DELETE", "OPTIONS", "PATCH"],
      @allowed_headers : Array(String) = ["Content-Type", "Authorization", "X-Requested-With"],
      @exposed_headers : Array(String) = ["X-Request-ID", "X-Response-Time"],
      @max_age = 86400, # 24 hours
      @allow_credentials = false,
    )
    end

    def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
      origin = context.request.headers["Origin"]?

      # Handle preflight OPTIONS requests
      if context.request.headers["X-HTTP-Method"]? == "OPTIONS"
        handle_preflight(context, origin)
        return
      end

      # Add CORS headers for actual requests
      if origin
        set_cors_headers(context, origin)
      end

      # Continue chain
      next_middleware.try(&.call(context))

      # Ensure CORS headers are set on response
      if origin && !context.response.headers.has_key?("Access-Control-Allow-Origin")
        set_cors_headers(context, origin)
      end
    end

    # Handles CORS preflight requests (OPTIONS method).
    # Sets appropriate CORS headers and responds with 204 No Content.
    private def handle_preflight(context : Micro::Core::Context, origin : String?) : Nil
      if origin && is_origin_allowed?(origin)
        set_cors_headers(context, origin)

        # Add preflight-specific headers
        if requested_method = context.request.headers["Access-Control-Request-Method"]?
          context.response.headers["Access-Control-Allow-Methods"] = @allowed_methods.join(", ")
        end

        if requested_headers = context.request.headers["Access-Control-Request-Headers"]?
          context.response.headers["Access-Control-Allow-Headers"] = @allowed_headers.join(", ")
        end

        context.response.headers["Access-Control-Max-Age"] = @max_age.to_s
      end

      context.response.status = 204 # No Content
      context.response.body = nil
    end

    # Sets CORS response headers based on configuration.
    # Includes Access-Control headers for origin, methods, and credentials.
    private def set_cors_headers(context : Micro::Core::Context, origin : String) : Nil
      if is_origin_allowed?(origin)
        # Set allowed origin
        if @allowed_origins.includes?("*") && !@allow_credentials
          context.response.headers["Access-Control-Allow-Origin"] = "*"
        else
          context.response.headers["Access-Control-Allow-Origin"] = origin
        end

        # Set credentials header if enabled
        if @allow_credentials
          context.response.headers["Access-Control-Allow-Credentials"] = "true"
        end

        # Set exposed headers
        unless @exposed_headers.empty?
          context.response.headers["Access-Control-Expose-Headers"] = @exposed_headers.join(", ")
        end

        # Vary header for caching
        add_vary_header(context.response.headers, "Origin")
      end
    end

    # Checks if the given origin is allowed by CORS configuration.
    # Returns true for wildcard (*) or if origin is in allowed list.
    private def is_origin_allowed?(origin : String) : Bool
      return true if @allowed_origins.includes?("*")
      @allowed_origins.includes?(origin)
    end

    # Adds a value to the Vary header for proper caching.
    # Appends to existing Vary header or creates new one.
    private def add_vary_header(headers : HTTP::Headers, value : String) : Nil
      if existing = headers["Vary"]?
        unless existing.includes?(value)
          headers["Vary"] = "#{existing}, #{value}"
        end
      else
        headers["Vary"] = value
      end
    end
  end
end
