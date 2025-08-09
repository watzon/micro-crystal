# Middleware implementations for micro-crystal.
#
# This module provides a comprehensive set of middleware for common
# cross-cutting concerns in microservices. All middleware follows the
# same interface pattern and can be composed together.
#
# ## Available Middleware
#
# ### Error Handling & Recovery
# - `RecoveryMiddleware` - Catches panics and prevents crashes
# - `ErrorHandlerMiddleware` - Formats errors with proper status codes
#
# ### Request Tracking & Logging
# - `RequestIDMiddleware` - Ensures unique request IDs
# - `LoggingMiddleware` - Structured request/response logging
# - `TimingMiddleware` - Adds response time measurements
#
# ### Security & Authentication
# - `AuthMiddleware` - Base authentication class
# - `BearerAuthMiddleware` - Bearer token/JWT authentication
# - `BasicAuthMiddleware` - HTTP Basic authentication
# - `APIKeyAuthMiddleware` - API key authentication
# - `CORSMiddleware` - Cross-Origin Resource Sharing
#
# ### Performance & Protection
# - `RateLimitMiddleware` - Fixed window rate limiting
# - `TokenBucketRateLimitMiddleware` - Token bucket rate limiting
# - `CompressionMiddleware` - gzip/deflate compression
# - `TimeoutMiddleware` - Request timeout enforcement
#
# ## Usage
# ```
# # Register default middleware
# Micro::Stdlib.register_default_middleware
#
# # Use in server
# server.use(Micro::Stdlib::RecoveryMiddleware.new)
# server.use(Micro::Stdlib::LoggingMiddleware.new)
# server.use(Micro::Stdlib::RateLimitMiddleware.new(60, 1.minute))
#
# # Use with annotations
# @[Micro::Middleware(["auth", "rate_limit"])]
# def protected_endpoint
#   # ...
# end
# ```

require "./middleware/auth_middleware"
require "./middleware/compression_middleware"
require "./middleware/cors_middleware"
require "./middleware/error_handler_middleware"
require "./middleware/jwt_auth_middleware"
require "./middleware/logging_middleware"
require "./middleware/rate_limit_middleware"
require "./middleware/recovery_middleware"
require "./middleware/request_id_middleware"
require "./middleware/request_size_middleware"
require "./middleware/timing_middleware"
require "./middleware/timeout_middleware"

module Micro::Stdlib
  # Export all middleware classes for convenience
  alias AuthMiddleware = Middleware::AuthMiddleware
  alias BearerAuthMiddleware = Middleware::BearerAuthMiddleware
  alias BasicAuthMiddleware = Middleware::BasicAuthMiddleware
  alias APIKeyAuthMiddleware = Middleware::APIKeyAuthMiddleware
  alias JWTAuthMiddleware = Middleware::JWTAuthMiddleware
  alias MultiTenantJWTAuthMiddleware = Middleware::MultiTenantJWTAuthMiddleware
  alias CompressionMiddleware = Middleware::CompressionMiddleware
  alias CORSMiddleware = Middleware::CORSMiddleware
  alias ErrorHandlerMiddleware = Middleware::ErrorHandlerMiddleware
  alias LoggingMiddleware = Middleware::LoggingMiddleware
  alias RateLimitMiddleware = Middleware::RateLimitMiddleware
  alias TokenBucketRateLimitMiddleware = Middleware::TokenBucketRateLimitMiddleware
  alias RecoveryMiddleware = Middleware::RecoveryMiddleware
  alias RequestIDMiddleware = Middleware::RequestIDMiddleware
  alias RequestSizeMiddleware = Middleware::RequestSizeMiddleware
  alias TimingMiddleware = Middleware::TimingMiddleware
  alias TimeoutMiddleware = Middleware::TimeoutMiddleware

  # Helper method to register common middleware
  def self.register_default_middleware : Nil
    # Register commonly used middleware with default configurations
    Micro::Core::MiddlewareRegistry.register("recovery", RecoveryMiddleware.new)
    Micro::Core::MiddlewareRegistry.register("error_handler", ErrorHandlerMiddleware.new)
    Micro::Core::MiddlewareRegistry.register("request_id", RequestIDMiddleware.new)
    Micro::Core::MiddlewareRegistry.register("timing", TimingMiddleware.new)
    Micro::Core::MiddlewareRegistry.register("logging", LoggingMiddleware.new)
    Micro::Core::MiddlewareRegistry.register("cors", CORSMiddleware.new)
    Micro::Core::MiddlewareRegistry.register("compression", CompressionMiddleware.new)
    Micro::Core::MiddlewareRegistry.register("request_size", RequestSizeMiddleware.new)

    # Register middleware factories for parameterized middleware
    Micro::Core::MiddlewareRegistry.register_factory("timeout") do |options|
      seconds = options["seconds"]?.try(&.as_f) || 30.0
      TimeoutMiddleware.new(seconds.seconds)
    end

    Micro::Core::MiddlewareRegistry.register_factory("rate_limit") do |options|
      limit = options["requests_per_minute"]?.try(&.as_i) || 60
      window = options["window_seconds"]?.try(&.as_f) || 60.0

      RateLimitMiddleware.new(
        limit: limit,
        window: window.seconds
      )
    end

    Micro::Core::MiddlewareRegistry.register_factory("auth") do |options|
      type = options["type"]?.try(&.as_s) || "bearer"

      case type.downcase
      when "bearer"
        # This is a placeholder - in real use, you'd provide a real validator
        validator = ->(token : String) {
          if token == "valid-token"
            Middleware::AuthResult::Success.new(user: "test-user", user_id: "123")
          else
            Middleware::AuthResult::Unauthorized.new("Invalid token")
          end
        }
        BearerAuthMiddleware.new(validator)
      when "jwt"
        # JWT specific configuration
        secret = options["secret"]?.try(&.as_s)
        public_key = options["public_key"]?.try(&.as_s)
        algorithm = case options["algorithm"]?.try(&.as_s)
                    when "HS256" then JWT::Algorithm::HS256
                    when "HS384" then JWT::Algorithm::HS384
                    when "HS512" then JWT::Algorithm::HS512
                    when "RS256" then JWT::Algorithm::RS256
                    when "RS384" then JWT::Algorithm::RS384
                    when "RS512" then JWT::Algorithm::RS512
                    when "ES256" then JWT::Algorithm::ES256
                    when "ES384" then JWT::Algorithm::ES384
                    when "ES512" then JWT::Algorithm::ES512
                    else              JWT::Algorithm::HS256
                    end
        issuer = options["issuer"]?.try(&.as_s)
        audience = options["audience"]?.try(&.as_s)

        JWTAuthMiddleware.new(
          secret: secret,
          public_key: public_key,
          algorithm: algorithm,
          issuer: issuer,
          audience: audience
        )
      when "basic"
        validator = ->(username : String, password : String) {
          if username == "admin" && password == "secret"
            Middleware::AuthResult::Success.new(user: username, user_id: "1")
          else
            Middleware::AuthResult::Unauthorized.new("Invalid credentials")
          end
        }
        BasicAuthMiddleware.new(validator)
      when "api_key"
        validator = ->(key : String) {
          if key == "valid-api-key"
            Middleware::AuthResult::Success.new(user: "api-user", user_id: "api-1")
          else
            Middleware::AuthResult::Unauthorized.new("Invalid API key")
          end
        }
        header = options["header"]?.try(&.as_s) || "X-API-Key"
        APIKeyAuthMiddleware.new(validator, header_name: header)
      else
        raise "Unknown auth type: #{type}"
      end
    end

    Micro::Core::MiddlewareRegistry.register_factory("request_size") do |options|
      max_size = options["max_size_mb"]?.try(&.as_f) || 1.0

      # Parse endpoint limits if provided
      endpoint_limits = {} of String => Int64
      if limits = options["endpoint_limits"]?.try(&.as_h)
        limits.each do |path, size|
          if size_mb = size.as_f?
            endpoint_limits[path] = (size_mb * 1024 * 1024).to_i64
          end
        end
      end

      # Parse exempt paths
      exempt_paths = if paths = options["exempt_paths"]?.try(&.as_a)
                       paths.map(&.as_s)
                     else
                       [] of String
                     end

      RequestSizeMiddleware.new(
        max_size: (max_size * 1024 * 1024).to_i64,
        endpoint_limits: endpoint_limits,
        exempt_paths: exempt_paths,
        check_content_length: options["check_content_length"]?.try(&.as_bool) || true,
        track_body_size: options["track_body_size"]?.try(&.as_bool) || false
      )
    end
  end
end
