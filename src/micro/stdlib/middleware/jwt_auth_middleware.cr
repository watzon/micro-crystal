require "../../core/middleware"
require "../../core/context"
require "./auth_middleware"
require "jwt"
require "json"

module Micro::Stdlib::Middleware
  # JWT authentication middleware implementing RFC 7519.
  #
  # This middleware validates JSON Web Tokens (JWTs) passed in the
  # Authorization header as Bearer tokens. It supports all standard
  # JWT claims and can be configured with various validation options.
  #
  # ## Features
  # - RS256, RS384, RS512, HS256, HS384, HS512, ES256, ES384, ES512, ED25519 algorithms
  # - Automatic expiration validation (exp claim)
  # - Not-before validation (nbf claim)
  # - Issuer validation (iss claim)
  # - Audience validation (aud claim)
  # - Subject extraction (sub claim)
  # - Custom claims support
  # - Key rotation support
  #
  # ## Usage
  # ```
  # # Simple HS256 with secret key
  # middleware = JWTAuthMiddleware.new(
  #   secret: "your-secret-key",
  #   algorithm: JWT::Algorithm::HS256
  # )
  #
  # # RS256 with public key
  # middleware = JWTAuthMiddleware.new(
  #   public_key: File.read("public_key.pem"),
  #   algorithm: JWT::Algorithm::RS256
  # )
  #
  # # With validation options
  # middleware = JWTAuthMiddleware.new(
  #   secret: "secret",
  #   algorithm: JWT::Algorithm::HS256,
  #   issuer: "my-app",
  #   audience: ["api", "web"],
  #   leeway: 30 # 30 seconds clock skew tolerance
  # )
  #
  # # With custom claims extractor
  # middleware = JWTAuthMiddleware.new(
  #   secret: "secret",
  #   algorithm: JWT::Algorithm::HS256,
  #   claims_extractor: ->(payload : JSON::Any) {
  #     {
  #       "roles"     => payload["roles"]?.try(&.as_a.map(&.as_s)),
  #       "tenant_id" => payload["tenant_id"]?.try(&.as_s),
  #     }
  #   }
  # )
  #
  # server.use(middleware)
  # ```
  #
  # ## Context Attributes Set
  # On successful authentication:
  # - `user` (String?) - Subject (sub) claim if present
  # - `user_id` (String?) - User ID from sub or custom user_id claim
  # - `jwt_claims` (Hash(String, JSON::Any)) - All JWT claims
  # - `jwt_token` (String) - Raw JWT token
  # - Additional custom metadata from claims_extractor
  #
  # ## Security Considerations
  # - Always use HTTPS in production
  # - Use strong secrets (minimum 256 bits for HMAC)
  # - Implement proper key rotation
  # - Set reasonable expiration times
  # - Validate issuer and audience claims
  # - Consider using asymmetric algorithms (RS256) for better security
  class JWTAuthMiddleware < BearerAuthMiddleware
    alias ClaimsExtractor = Proc(JSON::Any, Hash(String, JSON::Any)?)

    # Configuration options for JWT validation
    record Config,
      # Secret key for HMAC algorithms
      secret : String? = nil,
      # Public key for RSA/ECDSA algorithms
      public_key : String? = nil,
      # JWT signing algorithm
      algorithm : JWT::Algorithm = JWT::Algorithm::HS256,
      # Expected issuer
      issuer : String? = nil,
      # Expected audience(s)
      audience : String | Array(String) | Nil = nil,
      # Clock skew tolerance in seconds
      leeway : ::Int32 = 0,
      # Custom claims extractor
      claims_extractor : ClaimsExtractor? = nil,
      # Realm for WWW-Authenticate header
      realm : String = "JWT"

    def initialize(
      secret : String? = nil,
      public_key : String? = nil,
      algorithm : JWT::Algorithm = JWT::Algorithm::HS256,
      issuer : String? = nil,
      audience : String | Array(String) | Nil = nil,
      leeway : ::Int32 = 0,
      claims_extractor : ClaimsExtractor? = nil,
      realm : String = "JWT",
    )
      @config = Config.new(
        secret: secret,
        public_key: public_key,
        algorithm: algorithm,
        issuer: issuer,
        audience: audience,
        leeway: leeway,
        claims_extractor: claims_extractor,
        realm: realm
      )

      # Create the validator function for BearerAuthMiddleware
      validator = ->(token : String) { validate_jwt(token) }
      super(validator, realm)

      validate_configuration!
    end

    private def validate_configuration!
      case @config.algorithm
      when .hs256?, .hs384?, .hs512?
        unless @config.secret
          raise ArgumentError.new("Secret key required for HMAC algorithms")
        end
      when .rs256?, .rs384?, .rs512?, .es256?, .es384?, .es512?
        unless @config.public_key
          raise ArgumentError.new("Public key required for #{@config.algorithm} algorithm")
        end
      else
        raise ArgumentError.new("Unsupported algorithm: #{@config.algorithm}")
      end
    end

    private def validate_jwt(token : String) : AuthResult
      # Decode and verify the JWT
      payload, header = JWT.decode(
        token,
        verification_key,
        @config.algorithm,
        validate: true,
        # Standard claim validations
        iss: @config.issuer,
        aud: @config.audience,
        # Handle clock skew
        leeway: @config.leeway
      )

      # Extract user information
      claims = JSON.parse(payload.to_json)

      # Get user identifier
      user = claims["sub"]?.try(&.as_s)
      user_id = claims["user_id"]?.try(&.as_s) || user

      # Store all claims in metadata
      metadata = Hash(String, String).new
      metadata["jwt_claims"] = payload.to_json
      metadata["jwt_token"] = token

      # Extract custom claims if configured
      if extractor = @config.claims_extractor
        if custom_data = extractor.call(claims)
          custom_data.each do |key, value|
            metadata[key] = value.to_json
          end
        end
      end

      AuthResult::Success.new(
        user: user,
        user_id: user_id,
        metadata: metadata
      )
    rescue ex : JWT::ExpiredSignatureError
      AuthResult::Unauthorized.new("Token has expired")
    rescue ex : JWT::ImmatureSignatureError
      AuthResult::Unauthorized.new("Token is not yet valid")
    rescue ex : JWT::InvalidIssuerError
      AuthResult::Unauthorized.new("Invalid token issuer")
    rescue ex : JWT::InvalidAudienceError
      AuthResult::Unauthorized.new("Invalid token audience")
    rescue ex : JWT::VerificationError
      AuthResult::Unauthorized.new("Invalid token signature")
    rescue ex : JWT::DecodeError
      AuthResult::Unauthorized.new("Invalid token format")
    rescue ex
      # Log unexpected errors in production
      AuthResult::Unauthorized.new("Token validation failed")
    end

    private def verification_key : String
      case @config.algorithm
      when .hs256?, .hs384?, .hs512?
        @config.secret || raise ArgumentError.new("JWT secret required for HMAC algorithms")
      else
        @config.public_key || raise ArgumentError.new("JWT public key required for RSA/ECDSA algorithms")
      end
    end

    # Override to provide JWT-specific challenge
    protected def challenge_header : String
      %Q{Bearer realm="#{@config.realm}", error="invalid_token"}
    end

    # Override call to add JWT-specific context attributes
    def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
      # Call parent implementation
      super

      # If authentication succeeded, add JWT-specific attributes
      if context.get("user", String)
        # Parse stored JWT claims
        if claims_json = context.get("jwt_claims", String)
          if claims = JSON.parse(claims_json.as(String))
            context.set("jwt_claims", claims)
          end
        end
      end
    end
  end

  # Multi-tenant JWT authentication middleware.
  #
  # This extends JWTAuthMiddleware to support multi-tenant applications
  # where different tenants may have different JWT configurations.
  #
  # ## Usage
  # ```
  # # Configure tenants
  # tenants = {
  #   "tenant1" => JWTAuthMiddleware::Config.new(
  #     secret: "tenant1-secret",
  #     algorithm: JWT::Algorithm::HS256
  #   ),
  #   "tenant2" => JWTAuthMiddleware::Config.new(
  #     public_key: File.read("tenant2-public.pem"),
  #     algorithm: JWT::Algorithm::RS256
  #   ),
  # }
  #
  # # Create middleware with tenant resolver
  # middleware = MultiTenantJWTAuthMiddleware.new(
  #   tenant_configs: tenants,
  #   tenant_resolver: ->(context : Micro::Core::Context) {
  #     # Extract tenant from subdomain, header, or path
  #     context.request.headers["X-Tenant-ID"]?
  #   }
  # )
  #
  # server.use(middleware)
  # ```
  class MultiTenantJWTAuthMiddleware < AuthMiddleware
    alias TenantResolver = Proc(Micro::Core::Context, String?)

    def initialize(
      @tenant_configs : Hash(String, JWTAuthMiddleware::Config),
      @tenant_resolver : TenantResolver,
      @default_config : JWTAuthMiddleware::Config? = nil,
      realm : String = "JWT",
    )
      super(realm)
    end

    def authenticate(context : Micro::Core::Context) : AuthResult
      # Resolve tenant
      tenant_id = @tenant_resolver.call(context)

      # Get tenant config or use default
      config = if tenant_id && (tenant_config = @tenant_configs[tenant_id]?)
                 tenant_config
               elsif @default_config
                 @default_config
               else
                 return AuthResult::Unauthorized.new("Unknown tenant")
               end

      # Store tenant ID in context for later use
      context.set("tenant_id", tenant_id) if tenant_id

      # Create a temporary JWT middleware with tenant config
      # config is guaranteed to be non-nil here due to early return above
      jwt_middleware = JWTAuthMiddleware.new(
        secret: config.not_nil!.secret,
        public_key: config.not_nil!.public_key,
        algorithm: config.not_nil!.algorithm,
        issuer: config.not_nil!.issuer,
        audience: config.not_nil!.audience,
        leeway: config.not_nil!.leeway,
        claims_extractor: config.not_nil!.claims_extractor,
        realm: config.not_nil!.realm
      )

      # Delegate to JWT middleware
      jwt_middleware.authenticate(context)
    end

    protected def challenge_header : String
      %Q{Bearer realm="#{@realm}", error="invalid_token"}
    end
  end
end
