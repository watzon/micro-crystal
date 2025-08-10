require "../../core/middleware"
require "../../core/context"
require "base64"

module Micro::Stdlib::Middleware
  # Base class for authentication middleware implementations.
  #
  # This abstract class provides the common authentication flow and error handling
  # for all authentication schemes. Subclasses implement specific authentication
  # methods (Bearer, Basic, API Key, etc.).
  #
  # ## Features
  # - Unified authentication interface
  # - Stores user info in context on success
  # - Returns proper HTTP status codes (401/403)
  # - Adds WWW-Authenticate challenge headers
  # - Supports custom authentication realms
  #
  # ## Authentication Flow
  # 1. Calls `authenticate` to verify credentials
  # 2. On success: stores user data in context and continues
  # 3. On unauthorized: returns 401 with challenge header
  # 4. On forbidden: returns 403 with error message
  #
  # ## Context Attributes
  # On successful authentication, these are set:
  # - `user` (String?) - Username or identifier
  # - `user_id` (String?) - Unique user ID
  # - Additional metadata from AuthResult
  #
  # ## Custom Implementation
  # ```
  # class MyAuthMiddleware < AuthMiddleware
  #   def authenticate(context) : AuthResult
  #     # Your authentication logic
  #   end
  #
  #   protected def challenge_header : String
  #     "MyScheme realm=\"#{@realm}\""
  #   end
  # end
  # ```
  abstract class AuthMiddleware
    include Micro::Core::Middleware

    def initialize(@realm : String = "Restricted")
    end

    abstract def authenticate(context : Micro::Core::Context) : AuthResult

    def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
      result = authenticate(context)

      case result
      when AuthResult::Success
        # Store authenticated user/identity in context
        if user = result.user
          context.set("user", user)
        end
        if user_id = result.user_id
          context.set("user_id", user_id)
        end

        # Store additional metadata if provided
        if meta = result.metadata
          meta.each do |key, value|
            context.set(key, value)
          end
        end

        # Continue chain
        next_middleware.try(&.call(context))
      when AuthResult::Unauthorized
        handle_unauthorized(context, result.message)
      when AuthResult::Forbidden
        handle_forbidden(context, result.message)
      end
    end

    protected def handle_unauthorized(context : Micro::Core::Context, message : String?) : Nil
      context.response.status = 401
      context.response.headers["WWW-Authenticate"] = challenge_header
      context.response.body = {
        "error" => message || "Authentication required",
      }
    end

    protected def handle_forbidden(context : Micro::Core::Context, message : String?) : Nil
      context.response.status = 403
      context.response.body = {
        "error" => message || "Access forbidden",
      }
    end

    protected abstract def challenge_header : String
  end

  # Authentication result
  abstract struct AuthResult
    struct Success < AuthResult
      getter user : String?
      getter user_id : String?
      getter metadata : Hash(String, String)?

      def initialize(@user = nil, @user_id = nil, @metadata = nil)
      end
    end

    struct Unauthorized < AuthResult
      getter message : String?

      def initialize(@message = nil)
      end
    end

    struct Forbidden < AuthResult
      getter message : String?

      def initialize(@message = nil)
      end
    end
  end

  # Implements Bearer token authentication (RFC 6750).
  #
  # This middleware validates JWT or opaque bearer tokens passed in the
  # Authorization header. It's commonly used for OAuth 2.0, JWT authentication,
  # and API access tokens.
  #
  # ## Usage
  # ```
  # # Create validator function
  # validator = ->(token : String) {
  #   if user = validate_jwt(token)
  #     AuthResult::Success.new(
  #       user: user.email,
  #       user_id: user.id.to_s
  #     )
  #   else
  #     AuthResult::Unauthorized.new("Invalid token")
  #   end
  # }
  #
  # server.use(BearerAuthMiddleware.new(validator))
  # ```
  #
  # ## Request Format
  # ```
  # Authorization: Bearer eyJhbGciOiJIUzI1NiIs...
  # ```
  #
  # ## Security Notes
  # - Always use HTTPS in production
  # - Implement token expiration
  # - Consider token refresh mechanisms
  # - Validate token signatures for JWTs
  class BearerAuthMiddleware < AuthMiddleware
    alias TokenValidator = Proc(String, AuthResult)

    def initialize(@validator : TokenValidator, @realm : String = "Restricted")
      super(@realm)
    end

    def authenticate(context : Micro::Core::Context) : AuthResult
      auth_header = context.request.headers["Authorization"]?

      unless auth_header
        return AuthResult::Unauthorized.new("Missing Authorization header")
      end

      unless auth_header.starts_with?("Bearer ")
        return AuthResult::Unauthorized.new("Invalid Authorization header format")
      end

      token = auth_header[7..]

      if token.empty?
        return AuthResult::Unauthorized.new("Empty bearer token")
      end

      @validator.call(token)
    end

    protected def challenge_header : String
      %Q{Bearer realm="#{@realm}"}
    end
  end

  # Implements HTTP Basic authentication (RFC 7617).
  #
  # This middleware validates username/password credentials passed in the
  # Authorization header using Base64 encoding. While simple to implement,
  # it should only be used over HTTPS.
  #
  # ## Usage
  # ```
  # # Create validator function
  # validator = ->(username : String, password : String) {
  #   if user = User.authenticate(username, password)
  #     AuthResult::Success.new(
  #       user: username,
  #       user_id: user.id.to_s
  #     )
  #   else
  #     AuthResult::Unauthorized.new("Invalid credentials")
  #   end
  # }
  #
  # server.use(BasicAuthMiddleware.new(validator))
  # ```
  #
  # ## Request Format
  # ```
  # # Username: john, Password: secret
  # Authorization: Basic am9objpzZWNyZXQ=
  # ```
  #
  # ## Security Warnings
  # - MUST use HTTPS - credentials are only Base64 encoded
  # - Credentials sent with every request
  # - No built-in session management
  # - Consider more secure alternatives for production
  class BasicAuthMiddleware < AuthMiddleware
    alias CredentialsValidator = Proc(String, String, AuthResult)

    def initialize(@validator : CredentialsValidator, @realm : String = "Restricted")
      super(@realm)
    end

    def authenticate(context : Micro::Core::Context) : AuthResult
      auth_header = context.request.headers["Authorization"]?

      unless auth_header
        return AuthResult::Unauthorized.new("Missing Authorization header")
      end

      unless auth_header.starts_with?("Basic ")
        return AuthResult::Unauthorized.new("Invalid Authorization header format")
      end

      encoded = auth_header[6..]

      begin
        decoded = Base64.decode_string(encoded)
        parts = decoded.split(':', 2)

        if parts.size != 2
          return AuthResult::Unauthorized.new("Invalid credentials format")
        end

        username, password = parts
        @validator.call(username, password)
      rescue ex : Base64::Error
        AuthResult::Unauthorized.new("Invalid Base64 encoding")
      end
    end

    protected def challenge_header : String
      %Q{Basic realm="#{@realm}"}
    end
  end

  # Implements API key authentication via headers or query parameters.
  #
  # This middleware validates API keys that can be passed either in a custom
  # header or as a query parameter. It's commonly used for service-to-service
  # authentication and public API access.
  #
  # ## Usage
  # ```
  # # Create validator function
  # validator = ->(key : String) {
  #   if api_key = APIKey.find_valid(key)
  #     AuthResult::Success.new(
  #       user: api_key.name,
  #       user_id: api_key.id.to_s,
  #       metadata: {"scope" => api_key.scope}
  #     )
  #   else
  #     AuthResult::Unauthorized.new("Invalid API key")
  #   end
  # }
  #
  # # Header-based (default)
  # server.use(APIKeyAuthMiddleware.new(validator))
  #
  # # Custom header name
  # server.use(APIKeyAuthMiddleware.new(validator, "X-Custom-Key"))
  #
  # # Also check query parameter
  # server.use(APIKeyAuthMiddleware.new(
  #   validator,
  #   header_name: "X-API-Key",
  #   query_param: "api_key"
  # ))
  # ```
  #
  # ## Request Formats
  # ```
  # # Header
  # X-API-Key: sk-1234567890abcdef
  #
  # # Query parameter
  # GET /api/users?api_key=sk-1234567890abcdef
  # ```
  #
  # ## Security Best Practices
  # - Use secure random keys (e.g., 32+ characters)
  # - Implement key rotation
  # - Rate limit by API key
  # - Scope keys to specific permissions
  # - Log key usage for auditing
  class APIKeyAuthMiddleware < AuthMiddleware
    alias KeyValidator = Proc(String, AuthResult)

    def initialize(
      @validator : KeyValidator,
      @header_name : String = "X-API-Key",
      @query_param : String? = "api_key",
      @realm : String = "API",
    )
      super(@realm)
    end

    def authenticate(context : Micro::Core::Context) : AuthResult
      # Try header first
      if api_key = context.request.headers[@header_name]?
        return @validator.call(api_key)
      end

      # Try query parameter if configured
      if param_name = @query_param
        # Extract from query string if available
        if query = context.request.headers["X-Query-String"]?
          params = HTTP::Params.parse(query)
          if api_key = params[param_name]?
            return @validator.call(api_key)
          end
        end
      end

      AuthResult::Unauthorized.new("Missing API key")
    end

    protected def challenge_header : String
      %Q{ApiKey realm="#{@realm}"}
    end
  end
end
