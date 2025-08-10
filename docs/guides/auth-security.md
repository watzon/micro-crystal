# Authentication & Security Guide

This guide covers authentication and security features in µCrystal, including JWT, mTLS, RBAC, and security best practices.

## Table of Contents

- [Authentication Overview](#authentication-overview)
- [JWT Authentication](#jwt-authentication)
- [Basic Authentication](#basic-authentication)
- [API Key Authentication](#api-key-authentication)
- [mTLS (Mutual TLS)](#mtls-mutual-tls)
- [Role-Based Access Control (RBAC)](#role-based-access-control-rbac)
- [Security Headers](#security-headers)
- [Data Protection](#data-protection)
- [Best Practices](#best-practices)

## Authentication Overview

µCrystal supports multiple authentication methods that can be used individually or combined:

- **JWT (Bearer tokens)**: Stateless authentication for APIs
- **Basic Auth**: Simple username/password (use only over HTTPS)
- **API Keys**: Service-to-service or client authentication
- **mTLS**: Certificate-based mutual authentication
- **Custom**: Implement your own authentication strategy

## JWT Authentication

### Basic JWT Setup

```crystal
@[Micro::Service(name: "api", version: "1.0.0")]
@[Micro::Middleware(["auth"], options: {"type" => "jwt", "secret" => ENV["JWT_SECRET"]})]
class APIService
  include Micro::ServiceBase
  
  # All methods require JWT by default
  @[Micro::Method]
  def get_user_profile(ctx : Micro::Core::Context, req : GetProfileRequest) : UserProfile
    # Access authenticated user info
    user_id = ctx.get!("user_id", String)
    UserProfile.find(user_id)
  end
  
  # Skip auth for specific methods
  @[Micro::Method]
  @[Micro::AllowAnonymous]
  def health_check(ctx : Micro::Core::Context, req : Empty) : HealthStatus
    HealthStatus.new("healthy")
  end
end
```

### JWT Configuration

```crystal
# Configure JWT middleware in service options
options = Micro::Core::Service::Options.new(
  name: "api",
  version: "1.0.0",
  address: "0.0.0.0:8080",
  middleware: ["auth"],
  middleware_config: {
    "auth" => {
      "type" => "jwt",
      "secret" => ENV["JWT_SECRET"],           # HS256 secret
      "algorithm" => "HS256",                  # or RS256, ES256
      "issuer" => "https://api.example.com",   # Expected issuer
      "audience" => "api.example.com",         # Expected audience
      "leeway" => 60,                          # Seconds of leeway
    }
  }
)

APIService.run(options)
```

### Custom JWT validation

```crystal
require "jwt"

# Create a custom JWT middleware using the provided JWTAuthMiddleware
jwt_middleware = Micro::Stdlib::Middleware::JWTAuthMiddleware.new(
  secret: ENV["JWT_SECRET"],
  algorithm: JWT::Algorithm::HS256,
  issuer: "https://api.example.com",
  audience: "api.example.com",
  leeway: 60,
  claims_extractor: ->(payload : JSON::Any) {
    # Extract custom claims
    {
      "roles" => payload["roles"]?,
      "tenant_id" => payload["tenant_id"]?,
      "permissions" => payload["permissions"]?
    }
  }
)

# Use in service configuration
options = Micro::Core::Service::Options.new(
  name: "api",
  version: "1.0.0",
  custom_middleware: [jwt_middleware]
)
```

### Generating JWTs

```crystal
@[Micro::Service(name: "auth", version: "1.0.0")]
class AuthService
  include Micro::ServiceBase
  
  @[Micro::Method]
  @[Micro::AllowAnonymous]
  def login(ctx : Micro::Core::Context, credentials : LoginRequest) : LoginResponse
    user = authenticate_user(credentials.username, credentials.password)
    
    unless user
      raise Micro::UnauthorizedError.new("Invalid credentials")
    end
    
    # Generate JWT
    payload = {
      "sub" => user.id.to_s,
      "email" => user.email,
      "roles" => user.roles,
      "scope" => user.permissions.join(" "),
      "iat" => Time.utc.to_unix,
      "exp" => 1.hour.from_now.to_unix,
      "iss" => "https://api.example.com",
      "aud" => "api.example.com"
    }
    
    token = JWT.encode(payload, ENV["JWT_SECRET"], JWT::Algorithm::HS256)
    
    LoginResponse.new(
      access_token: token,
      token_type: "Bearer",
      expires_in: 3600,
      refresh_token: generate_refresh_token(user)
    )
  end
  
  @[Micro::Method]
  @[Micro::AllowAnonymous]
  def refresh(ctx : Micro::Core::Context, request : RefreshRequest) : LoginResponse
    # Validate refresh token and issue new JWT
    user = validate_refresh_token(request.refresh_token)
    
    # Generate new tokens...
  end
end
```

## Basic Authentication

### Setup Basic Auth

```crystal
@[Micro::Service(name: "admin", version: "1.0.0")]
@[Micro::Middleware(["auth"], options: {"type" => "basic"})]
class AdminService
  include Micro::ServiceBase
  
  # Configure basic auth with custom validator
  def self.create_auth_middleware
    Micro::Stdlib::Middleware::BasicAuthMiddleware.new(
      ->(username : String, password : String) {
        # Validate credentials
        if user = User.authenticate(username, password)
          Micro::Stdlib::Middleware::AuthResult::Success.new(
            user: username,
            user_id: user.id.to_s
          )
        else
          Micro::Stdlib::Middleware::AuthResult::Unauthorized.new("Invalid credentials")
        end
      },
      realm: "Admin Panel"
    )
  end
  
  # Methods require basic auth by default
  @[Micro::Method]
  def admin_action(ctx : Micro::Core::Context, req : AdminRequest) : AdminResponse
    # Access authenticated user
    username = ctx.get!("user", String)
    # ...
  end
end
```

### Secure Password Storage

```crystal
require "crypto/bcrypt/password"

class User
  property username : String
  property password_hash : String
  
  def self.create(username : String, password : String) : User
    # Hash password with bcrypt
    password_hash = Crypto::Bcrypt::Password.create(password, cost: 12).to_s
    
    User.new(username: username, password_hash: password_hash)
  end
  
  def self.authenticate(username : String, password : String) : User?
    user = find_by_username(username)
    return nil unless user
    
    # Verify password
    bcrypt = Crypto::Bcrypt::Password.new(user.password_hash)
    return nil unless bcrypt.verify(password)
    
    user
  end
end
```

## API Key Authentication

### Basic API Key Setup

```crystal
@[Micro::Service(name: "data-api", version: "1.0.0")]
class DataAPIService
  include Micro::ServiceBase
  
  def self.create_api_key_middleware
    Micro::Stdlib::Middleware::APIKeyAuthMiddleware.new(
      ->(key : String) {
        # Validate API key
        if api_key = APIKey.find_valid(key)
          Micro::Stdlib::Middleware::AuthResult::Success.new(
            user: api_key.name,
            user_id: api_key.id.to_s,
            metadata: {
              "rate_limit" => api_key.rate_limit.to_s,
              "scopes" => api_key.scopes.join(",")
            }
          )
        else
          Micro::Stdlib::Middleware::AuthResult::Unauthorized.new("Invalid API key")
        end
      },
      header_name: "X-API-Key",
      query_param: "api_key"  # Also accept in query string
    )
  end
end

# Use in service configuration
options = Micro::Core::Service::Options.new(
  name: "data-api",
  version: "1.0.0",
  custom_middleware: [DataAPIService.create_api_key_middleware]
)

DataAPIService.run(options)
```

### API Key Management

```crystal
class APIKey
  property id : String
  property key : String
  property name : String
  property scopes : Array(String)
  property rate_limit : Int32
  property expires_at : Time?
  property last_used_at : Time?
  
  def self.generate(name : String, scopes : Array(String)) : APIKey
    # Generate secure random key
    key = "sk_#{Random::Secure.urlsafe_base64(32)}"
    
    APIKey.new(
      id: UUID.random.to_s,
      key: key,
      name: name,
      scopes: scopes,
      rate_limit: 1000,  # requests per hour
      expires_at: 1.year.from_now
    )
  end
  
  def self.find_valid(key : String) : APIKey?
    api_key = find_by_key(key)
    return nil unless api_key
    
    # Check expiration
    if expires = api_key.expires_at
      return nil if expires < Time.utc
    end
    
    # Update last used
    api_key.last_used_at = Time.utc
    api_key.save
    
    api_key
  end
  
  def valid_for_scope?(required_scope : String) : Bool
    scopes.includes?(required_scope) || scopes.includes?("*")
  end
end
```

## mTLS (Mutual TLS)

### Server-Side mTLS

```crystal
require "openssl"

# Configure service with TLS
options = Micro::Core::Service::Options.new(
  name: "secure-service",
  version: "1.0.0",
  address: "0.0.0.0:8443",
  tls_config: {
    "cert_path" => "/path/to/server.crt",
    "key_path" => "/path/to/server.key",
    "ca_path" => "/path/to/ca.crt",     # For client verification
    "verify_mode" => "peer",             # Require client certificates
    "min_version" => "1.2"               # Minimum TLS version
  }
)

SecureService.run(options)
```

### Client Certificate Authentication

```crystal
class ClientCertMiddleware
  include Micro::Core::Middleware
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    # Extract client certificate from context
    # In actual TLS termination, the cert would be in the connection context
    if cert_header = context.request.headers["X-Client-Cert"]?
      cert_pem = URI.decode(cert_header)
      cert = OpenSSL::X509::Certificate.new(cert_pem)
      
      # Extract subject info
      subject = cert.subject.to_s
      cn = extract_cn(subject)
      
      # Validate certificate
      unless valid_client_cert?(cert)
        context.response.status = 401
        context.response.body = {"error" => "Invalid client certificate"}.to_json.to_slice
        return
      end
      
      # Store client identity
      context.set("client_id", cn) if cn
      context.set("client_cert_subject", subject)
      
      # Create principal from certificate
      principal = Micro::Core::Auth::Principal.new(
        id: cn || "unknown",
        username: cn || "unknown",
        attributes: {
          "auth_method" => "mtls",
          "cert_subject" => subject
        }
      )
      context.set("auth:principal", principal)
    else
      context.response.status = 401
      context.response.body = {"error" => "Client certificate required"}.to_json.to_slice
      return
    end
    
    next_middleware.try(&.call(context))
  end
  
  private def extract_cn(subject : String) : String?
    if match = subject.match(/CN=([^,]+)/)
      match[1]
    end
  end
  
  private def valid_client_cert?(cert : OpenSSL::X509::Certificate) : Bool
    # Check expiration
    return false if cert.not_after < Time.utc
    return false if cert.not_before > Time.utc
    
    # Additional validation (CRL check, etc.)
    true
  end
end
```

### mTLS Client Configuration

```crystal
# Configure client with certificate
client_options = Micro::Stdlib::Client::Options.new(
  registry: registry,
  tls_config: {
    "cert_path" => "/path/to/client.crt",
    "key_path" => "/path/to/client.key",
    "ca_path" => "/path/to/ca.crt"
  }
)

client = Micro::Stdlib::Client.new(client_options)

# Make authenticated request
response = client.call(
  service: "secure-service",
  method: "protected_method",
  body: request_body
)
```

## Role-Based Access Control (RBAC)

### Basic RBAC Setup

```crystal
@[Micro::Service(name: "api", version: "1.0.0")]
@[Micro::Middleware(["auth", "role_guard"])]
class APIService
  include Micro::ServiceBase
  
  # Public method - any authenticated user
  @[Micro::Method]
  def get_profile(ctx : Micro::Core::Context, req : GetProfileRequest) : UserProfile
    user_id = ctx.get!("user_id", String)
    UserProfile.find(user_id)
  end
  
  # Requires specific role
  @[Micro::Method]
  @[Micro::RequireRole("admin")]
  def delete_user(ctx : Micro::Core::Context, req : DeleteUserRequest) : Bool
    User.delete(req.user_id)
  end
  
  # Requires any of the roles
  @[Micro::Method]
  @[Micro::RequireRole(["admin", "moderator"])]
  def ban_user(ctx : Micro::Core::Context, req : BanUserRequest) : Bool
    User.ban(req.user_id, req.reason)
  end
  
  # Requires all roles
  @[Micro::Method]
  @[Micro::RequireRole(["admin", "security"], require_all: true)]
  def view_audit_logs(ctx : Micro::Core::Context, req : Empty) : Array(AuditLog)
    AuditLog.recent
  end
end
```

### Custom RBAC Middleware

```crystal
# Use the built-in RoleGuard middleware
role_guard = Micro::Stdlib::Middleware::RoleGuard.new(
  required_roles: ["admin", "moderator"],
  require_all: false  # Require any of the roles
)

# Or create from configuration
role_config = {
  "roles" => ["admin", "moderator"],
  "require_all" => false
}
role_guard = Micro::Stdlib::Middleware::RoleGuard.from_config(role_config)

# Use in service configuration
options = Micro::Core::Service::Options.new(
  name: "api",
  version: "1.0.0",
  custom_middleware: [role_guard]
)
```

### Permission-Based Access Control

```crystal
# Use the built-in PermissionGuard middleware
permission_guard = Micro::Stdlib::Middleware::PermissionGuard.new(
  permissions: ["users:read", "users:write"],
  require_all: false  # Require any of the permissions
)

# Or create from configuration
permission_config = {
  "permissions" => ["users:read:own", "users:write:own"],
  "require_all" => true
}
permission_guard = Micro::Stdlib::Middleware::PermissionGuard.from_config(permission_config)

# Use with annotations
@[Micro::Service(name: "api")]
class APIService
  include Micro::ServiceBase
  
  @[Micro::Method]
  @[Micro::RequirePermission("users:read")]
  def list_users(ctx : Micro::Core::Context, req : ListUsersRequest) : Array(User)
    User.all
  end
  
  @[Micro::Method]
  @[Micro::RequirePermission(["users:write", "admin:all"], require_all: false)]
  def create_user(ctx : Micro::Core::Context, req : CreateUserRequest) : User
    User.create(req.to_h)
  end
end
```

## Security Headers

### Comprehensive Security Headers

```crystal
class SecurityHeadersMiddleware
  include Micro::Core::Middleware
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    # Process request
    next_middleware.try(&.call(context))
    
    # Add security headers to response
    headers = context.response.headers
    
    # Prevent XSS
    headers["X-XSS-Protection"] = "1; mode=block"
    headers["X-Content-Type-Options"] = "nosniff"
    
    # Prevent clickjacking
    headers["X-Frame-Options"] = "DENY"
    
    # HTTPS enforcement
    headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    
    # CSP
    headers["Content-Security-Policy"] = build_csp
    
    # Referrer policy
    headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    
    # Permissions policy
    headers["Permissions-Policy"] = "geolocation=(), microphone=(), camera=()"
  end
  
  private def build_csp : String
    [
      "default-src 'self'",
      "script-src 'self' 'unsafe-inline' 'unsafe-eval'",  # Adjust as needed
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: https:",
      "font-src 'self'",
      "connect-src 'self'",
      "media-src 'none'",
      "object-src 'none'",
      "frame-ancestors 'none'",
      "base-uri 'self'",
      "form-action 'self'"
    ].join("; ")
  end
end
```

## Data Protection

### Request/Response Encryption

```crystal
class EncryptionMiddleware
  include Micro::Core::Middleware
  
  def initialize(@key : Bytes)
    @cipher = OpenSSL::Cipher.new("aes-256-gcm")
  end
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    # Decrypt request if encrypted
    if context.request.headers["X-Encrypted"]? == "true"
      decrypted_body = decrypt(context.request.body)
      context.request.body = decrypted_body
    end
    
    # Process request
    next_middleware.try(&.call(context))
    
    # Encrypt response if requested
    if context.request.headers["X-Request-Encryption"]? == "true"
      encrypted_body = encrypt(context.response.body_bytes)
      context.response.body = encrypted_body
      context.response.headers["X-Encrypted"] = "true"
    end
  end
  
  private def encrypt(data : Bytes) : Bytes
    @cipher.encrypt
    @cipher.key = @key
    
    iv = Random::Secure.random_bytes(12)
    @cipher.iv = iv
    
    encrypted = @cipher.update(data)
    encrypted += @cipher.final
    tag = @cipher.auth_tag
    
    # Prepend IV and tag
    io = IO::Memory.new
    io.write(iv)
    io.write(tag)
    io.write(encrypted)
    io.to_slice
  end
  
  private def decrypt(data : Bytes) : Bytes
    # Extract IV, tag, and ciphertext
    iv = data[0...12]
    tag = data[12...28]
    ciphertext = data[28..]
    
    @cipher.decrypt
    @cipher.key = @key
    @cipher.iv = iv
    @cipher.auth_tag = tag
    
    decrypted = @cipher.update(ciphertext)
    decrypted + @cipher.final
  end
end
```

### Sensitive Data Masking

```crystal
class DataMaskingMiddleware
  include Micro::Core::Middleware
  
  SENSITIVE_FIELDS = ["password", "ssn", "credit_card", "api_key", "secret"]
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    # Store original request for internal use
    original_body = context.request.body
    
    # Mask sensitive data in logs
    if should_log?(context)
      masked_body = mask_sensitive_data(context.request.body)
      context.set("masked_request_body", masked_body)
    end
    
    # Process request
    next_middleware.try(&.call(context))
    
    # Mask sensitive data in response for logs
    if should_log?(context)
      masked_response = mask_sensitive_data(context.response.body_bytes)
      context.set("masked_response_body", masked_response)
    end
  end
  
  private def mask_sensitive_data(data : Bytes) : String
    begin
      json = JSON.parse(String.new(data))
      mask_json(json).to_json
    rescue
      "[BINARY DATA]"
    end
  end
  
  private def mask_json(value : JSON::Any) : JSON::Any
    case value
    when .as_h?
      hash = value.as_h
      masked = {} of String => JSON::Any
      
      hash.each do |key, val|
        if SENSITIVE_FIELDS.any? { |field| key.downcase.includes?(field) }
          masked[key] = JSON::Any.new("***MASKED***")
        else
          masked[key] = mask_json(val)
        end
      end
      
      JSON::Any.new(masked)
    when .as_a?
      JSON::Any.new(value.as_a.map { |v| mask_json(v) })
    else
      value
    end
  end
end
```

## Best Practices

### 1. Defense in Depth

Layer multiple security measures:

```crystal
@[Micro::Service(name: "secure-api", version: "1.0.0")]
@[Micro::Middleware([
  "request_id",
  "rate_limit",        # First line: rate limiting
  "auth",              # Second line: authentication
  "role_guard",        # Third line: authorization
  "compression",       # Fourth line: response compression
  "cors"              # Fifth line: CORS handling
])]
class SecureAPIService
  include Micro::ServiceBase
end

# Configure middleware in service options
options = Micro::Core::Service::Options.new(
  name: "secure-api",
  version: "1.0.0",
  middleware: ["request_id", "rate_limit", "auth", "role_guard"],
  middleware_config: {
    "auth" => {"type" => "jwt", "secret" => ENV["JWT_SECRET"]},
    "role_guard" => {"roles" => ["api_user"], "require_all" => false}
  }
)
```

### 2. Secure Defaults

Configure secure defaults for all services:

```crystal
module SecureDefaults
  def self.middleware_stack
    [
      "request_id",
      "security_headers",
      "rate_limit",
      "timeout",
      "error_handler"
    ]
  end
  
  def self.tls_config
    Micro::Stdlib::TLSConfig.new(
      min_version: OpenSSL::SSL::TLSVersion::TLS1_2,
      ciphers: "ECDHE+AESGCM:ECDHE+AES256:!aNULL:!MD5:!DSS"
    )
  end
  
  def self.cors_config
    {
      "allowed_origins" => [ENV["FRONTEND_URL"]],
      "allowed_methods" => ["GET", "POST"],
      "allowed_headers" => ["Content-Type", "Authorization"],
      "expose_headers" => ["X-Request-ID"],
      "max_age" => 3600,
      "credentials" => true
    }
  end
end
```

### 3. Input Validation

Always validate and sanitize inputs:

```crystal
# Use the built-in request size middleware
request_size_middleware = Micro::Stdlib::Middleware::RequestSizeMiddleware.new(
  max_size: 10 * 1024 * 1024  # 10MB limit
)

# Validate in service methods using typed requests
@[Micro::Service(name: "api")]
class APIService
  include Micro::ServiceBase
  
  @[Micro::Method]
  def create_user(ctx : Micro::Core::Context, req : CreateUserRequest) : User
    # Validation happens automatically during deserialization
    # Additional business logic validation
    validate_email_format(req.email)
    validate_password_strength(req.password)
    
    User.create(req.to_h)
  end
end

# Request types provide automatic validation
struct CreateUserRequest
  include JSON::Serializable
  
  @[JSON::Field(key: "email")]
  getter email : String
  
  @[JSON::Field(key: "password")]
  getter password : String
  
  @[JSON::Field(key: "name")]
  getter name : String
  
  def initialize(@email, @password, @name)
    raise ArgumentError.new("Email required") if @email.blank?
    raise ArgumentError.new("Password required") if @password.blank?
    raise ArgumentError.new("Name required") if @name.blank?
  end
end
```

### 4. Audit Everything

Comprehensive audit logging:

```crystal
class AuditLogger
  def self.log_access(context : Micro::Core::Context, result : Symbol)
    entry = {
      timestamp: Time.utc,
      request_id: context.get?("request_id"),
      user_id: context.get?("user_id"),
      client_id: context.get?("client_id"),
      method: context.request.headers["X-Method"]?,
      path: context.request.path,
      ip: extract_real_ip(context),
      user_agent: context.request.headers["User-Agent"]?,
      result: result,
      response_status: context.response.status,
      duration_ms: context.get?("request_duration")
    }
    
    # Log to secure audit trail
    AuditLog.create(entry)
    
    # Alert on suspicious activity
    if suspicious?(entry)
      SecurityAlert.trigger(entry)
    end
  end
  
  private def self.suspicious?(entry) : Bool
    # Multiple failed auth attempts
    recent_failures = AuditLog.where(
      user_id: entry[:user_id],
      result: :auth_failed,
      timestamp: 5.minutes.ago..Time.utc
    ).count
    
    recent_failures > 5
  end
end
```

### 5. Regular Security Updates

Keep dependencies and security configurations updated:

```crystal
```crystal
# Regularly rotate secrets
class SecretRotation
  Log = ::Log.for(self)
  
  def self.rotate_jwt_secret
    new_secret = Random::Secure.hex(32)
    
    # Update secret in secure storage
    SecretManager.update("JWT_SECRET", new_secret)
    
    # Grace period for old tokens
    SecretManager.set_previous("JWT_SECRET_OLD", ENV["JWT_SECRET"], ttl: 1.hour)
    
    # Update environment
    ENV["JWT_SECRET"] = new_secret
    
    Log.info { "JWT secret rotated successfully" }
  end
end

# Schedule regular rotations
spawn do
  loop do
    sleep 30.days
    SecretRotation.rotate_jwt_secret
    SecretRotation.rotate_api_keys
  end
end
```
```

## Next Steps

- Configure [Monitoring](monitoring.md) for security events
- Set up [API Gateway](api-gateway.md) with authentication
- Learn about [Testing](testing.md) security features
- Review [Service Development](service-development.md) with security in mind