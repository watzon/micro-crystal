# Middleware Guide

This guide covers µCrystal's middleware system, including built-in middleware, creating custom middleware, and middleware ordering strategies.

## Table of Contents

- [Understanding Middleware](#understanding-middleware)
- [Built-in Middleware](#built-in-middleware)
- [Using Middleware](#using-middleware)
- [Creating Custom Middleware](#creating-custom-middleware)
- [Middleware Ordering](#middleware-ordering)
- [Advanced Patterns](#advanced-patterns)
- [Best Practices](#best-practices)

## Understanding Middleware

Middleware in µCrystal provides a way to implement cross-cutting concerns that apply to multiple service methods. Each middleware forms a layer in the request/response pipeline.

### How Middleware Works

```crystal
# Request flow through middleware stack:
# Client Request
#   → RequestID Middleware (adds X-Request-ID)
#   → Logging Middleware (logs request)
#   → Auth Middleware (validates token)
#   → RateLimit Middleware (checks limits)
#   → Service Method (your business logic)
#   ← RateLimit Middleware (no action)
#   ← Auth Middleware (no action)
#   ← Logging Middleware (logs response)
#   ← RequestID Middleware (ensures X-Request-ID in response)
# Client Response
```

## Built-in Middleware

µCrystal provides a comprehensive set of middleware for common needs:

### Request ID Middleware

Ensures every request has a unique identifier for tracing:

```crystal
@[Micro::Middleware(["request_id"])]
```

Features:
- Generates UUID if X-Request-ID header missing
- Propagates ID to response headers
- Available in context as `request_id`

### Logging Middleware

Structured request/response logging:

```crystal
@[Micro::Middleware(["logging"])]
```

Features:
- Logs method, duration, status
- Excludes sensitive headers (Authorization, Cookie)
- Configurable log level via LOG_LEVEL env var

### Timing Middleware

Tracks request processing time:

```crystal
@[Micro::Middleware(["timing"])]
```

Features:
- Adds X-Response-Time header
- Useful for performance monitoring
- Measures full request lifecycle

### Error Handler Middleware

Graceful error handling and formatting:

```crystal
@[Micro::Middleware(["error_handler"])]
```

Features:
- Catches exceptions and returns proper HTTP status
- Formats errors as JSON
- Preserves error details in development
- Sanitizes errors in production

### CORS Middleware

Cross-Origin Resource Sharing support:

```crystal
@[Micro::Middleware(["cors"])]
```

Default configuration:
- Allow all origins (*)
- Common methods (GET, POST, PUT, DELETE, OPTIONS)
- Common headers (Content-Type, Authorization)
- 24-hour max age

### Compression Middleware

Response compression for bandwidth efficiency:

```crystal
@[Micro::Middleware(["compression"])]
```

Features:
- Gzip compression for responses > 1KB
- Respects Accept-Encoding header
- Skips already compressed content

### Authentication Middleware

Authentication is configured via the `auth` middleware with different types:

```crystal
# Bearer token (default)
@[Micro::Middleware(["auth"])]

# JWT authentication
@[Micro::Middleware(["auth"], options: {"type" => "jwt", "secret" => "your-secret"})]

# Basic auth
@[Micro::Middleware(["auth"], options: {"type" => "basic"})]

# API key
@[Micro::Middleware(["auth"], options: {"type" => "api_key", "header" => "X-API-Key"})]
```

### Rate Limiting Middleware

Protect against abuse:

```crystal
@[Micro::Middleware(["rate_limit"])]
```

Default limits:
- 1000 requests per minute per IP
- Returns 429 Too Many Requests when exceeded
- Adds X-RateLimit headers

### Request Size Middleware

Prevent oversized requests:

```crystal
@[Micro::Middleware(["request_size"])]
```

Features:
- Default 10MB limit
- Returns 413 Payload Too Large
- Configurable per middleware instance

### Timeout Middleware

Enforce request timeouts:

```crystal
@[Micro::Middleware(["timeout"])]
```

Features:
- Default 30-second timeout
- Returns 504 Gateway Timeout
- Cancels long-running operations

### Recovery Middleware

Panic recovery and graceful degradation:

```crystal
@[Micro::Middleware(["recovery"])]
```

Features:
- Catches panics and unhandled errors
- Returns 500 Internal Server Error
- Logs stack traces
- Prevents service crashes

## Using Middleware

### Service-Level Middleware

Apply middleware to all methods in a service:

```crystal
@[Micro::Service(name: "catalog", version: "1.0.0")]
@[Micro::Middleware([
  "request_id",
  "logging", 
  "timing",
  "error_handler",
  "cors",
  "compression"
])]
class CatalogService
  include Micro::ServiceBase
  
  # All methods use the middleware stack
end
```

### Method-Level Middleware

Override or add middleware for specific methods:

```crystal
@[Micro::Service(name: "api", version: "1.0.0")]
@[Micro::Middleware(["request_id", "logging"])]  # Service default
class APIService
  include Micro::ServiceBase
  
  @[Micro::Method]
  @[Micro::Middleware(["rate_limit"])]  # Additional for this method
  def public_endpoint(data : String) : Result
    # Has request_id, logging, AND rate_limit
  end
  
  @[Micro::Method]
  @[Micro::SkipMiddleware(["logging"])]  # Skip specific middleware
  def health_check : String
    # Has request_id but no logging
    "OK"
  end
end
```

### Configuring Middleware

Some middleware accepts configuration:

```crystal
# Middleware is configured when registering with the registry
# or via annotations with options

# Via annotation with options:
@[Micro::Middleware(["auth"], options: {
  "type" => "jwt",
  "secret" => ENV["JWT_SECRET"],
  "algorithm" => "HS256"
})]

@[Micro::Middleware(["rate_limit"], options: {
  "requests_per_minute" => 100,
  "window_seconds" => 60
})]

# When registering middleware programmatically:
Micro::Core::MiddlewareRegistry.register_factory("custom_cors") do |options|
  CORSMiddleware.new(
    allowed_origins: options["allowed_origins"]?.try(&.as_a).try(&.map(&.as_s)) || ["*"],
    allowed_methods: options["allowed_methods"]?.try(&.as_a).try(&.map(&.as_s)) || ["GET", "POST"],
    max_age: options["max_age"]?.try(&.as_i) || 3600
  )
end
```

## Creating Custom Middleware

### Basic Middleware Structure

```crystal
module MyApp::Middleware
  class CustomMiddleware
    include Micro::Core::Middleware
    
    def initialize(@config : Hash(String, JSON::Any) = {} of String => JSON::Any)
    end
    
    def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
      # Pre-processing
      before_request(context)
      
      # Call next middleware or handler
      next_middleware.try(&.call(context))
      
      # Post-processing
      after_response(context)
    end
    
    private def before_request(context : Micro::Core::Context)
      # Modify request, validate, etc.
    end
    
    private def after_response(context : Micro::Core::Context)
      # Modify response, log, etc.
    end
  end
end
```

### Example: API Version Middleware

```crystal
class APIVersionMiddleware
  include Micro::Core::Middleware
  
  def initialize(@supported_versions : Array(String) = ["v1", "v2"])
  end
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    # Extract version from header or path
    version = extract_version(context)
    
    unless @supported_versions.includes?(version)
      context.response.status = 400
      context.response.body = {
        error: "Unsupported API version: #{version}",
        supported: @supported_versions
      }
      return
    end
    
    # Store version in context
    context.set("api_version", version)
    
    # Continue processing
    next_middleware.try(&.call(context))
    
    # Add version to response
    context.response.headers["X-API-Version"] = version
  end
  
  private def extract_version(context) : String
    # Check header first
    if version = context.request.headers["X-API-Version"]?
      return version
    end
    
    # Check endpoint prefix
    if match = context.request.endpoint.match(%r{^api/(v\d+)/})
      return match[1]
    end
    
    # Default
    "v1"
  end
end
```

### Example: Caching Middleware

```crystal
class CachingMiddleware
  include Micro::Core::Middleware
  
  def initialize(@cache_duration : Time::Span = 5.minutes)
    @cache = {} of String => CachedResponse
  end
  
  struct CachedResponse
    getter body : Bytes
    getter headers : HTTP::Headers
    getter status : Int32
    getter cached_at : Time
    
    def initialize(@body, @headers, @status, @cached_at)
    end
    
    def expired?(duration : Time::Span) : Bool
      Time.utc - cached_at > duration
    end
  end
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    # For now, cache all read operations (you could check endpoint names)
    # In a real implementation, you'd have a way to mark cacheable methods
    
    cache_key = generate_cache_key(context)
    
    # Check cache
    if cached = @cache[cache_key]?
      unless cached.expired?(@cache_duration)
        # Serve from cache
        context.response.status = cached.status
        context.response.headers.merge!(cached.headers)
        context.response.headers["X-Cache"] = "HIT"
        context.response.body = cached.body
        return
      else
        @cache.delete(cache_key)
      end
    end
    
    # Process request
    next_middleware.try(&.call(context))
    
    # Cache successful responses
    if context.response.status < 400
      # Convert body to bytes for caching
      body_bytes = case body = context.response.body
                   when Bytes
                     body
                   when String
                     body.to_slice
                   when Nil
                     Bytes.empty
                   else
                     # Convert to JSON for other types
                     body.to_json.to_slice
                   end
      
      @cache[cache_key] = CachedResponse.new(
        body: body_bytes,
        headers: context.response.headers.dup,
        status: context.response.status,
        cached_at: Time.utc
      )
      context.response.headers["X-Cache"] = "MISS"
    end
  end
  
  private def generate_cache_key(context) : String
    # Include service, endpoint, and body hash
    service = context.request.service
    endpoint = context.request.endpoint
    body_hash = context.request.body.try(&.hash) || 0
    "#{service}:#{endpoint}:#{body_hash}"
  end
end
```

### Example: Audit Logging Middleware

```crystal
class AuditMiddleware
  include Micro::Core::Middleware
  
  Log = ::Log.for(self)
  
  def initialize(@sensitive_fields : Array(String) = ["password", "token", "secret"])
  end
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    # Capture request details
    audit_entry = {
      request_id: context.get?("request_id", String),
      user_id: context.get?("user_id", String),
      method: context.request.endpoint,
      service: context.request.service,
      timestamp: Time.utc,
      ip_address: extract_ip(context)
    }
    
    # Safely log request body
    if body = safe_parse_body(context.request.body)
      audit_entry["request_body"] = sanitize_sensitive(body)
    end
    
    # Process request
    start_time = Time.monotonic
    begin
      next_middleware.try(&.call(context))
      
      # Log successful completion
      audit_entry.merge!({
        status: context.response.status,
        duration_ms: (Time.monotonic - start_time).total_milliseconds,
        success: true
      })
    rescue ex
      # Log failure
      audit_entry.merge!({
        error: ex.message,
        error_type: ex.class.name,
        duration_ms: (Time.monotonic - start_time).total_milliseconds,
        success: false
      })
      raise ex
    ensure
      # Always log audit entry
      Log.info { audit_entry.to_json }
    end
  end
  
  private def extract_ip(context) : String?
    # Check X-Forwarded-For first
    if forwarded = context.request.headers["X-Forwarded-For"]?
      return forwarded.split(',').first.strip
    end
    
    # Fall back to remote address
    context.request.headers["Remote-Addr"]?
  end
  
  private def safe_parse_body(body : Bytes?) : JSON::Any?
    return nil unless body && body.size > 0
    
    JSON.parse(String.new(body))
  rescue
    nil
  end
  
  private def sanitize_sensitive(data : JSON::Any) : JSON::Any
    case data
    when .as_h?
      hash = data.as_h
      sanitized = {} of String => JSON::Any
      
      hash.each do |key, value|
        if @sensitive_fields.includes?(key.downcase)
          sanitized[key] = JSON::Any.new("[REDACTED]")
        else
          sanitized[key] = sanitize_sensitive(value)
        end
      end
      
      JSON::Any.new(sanitized)
    when .as_a?
      JSON::Any.new(data.as_a.map { |v| sanitize_sensitive(v) })
    else
      data
    end
  end
end
```

## Middleware Ordering

### Order Matters

Middleware executes in the order specified. Consider dependencies:

```crystal
@[Micro::Middleware([
  "request_id",      # First: generates ID for logging
  "logging",         # Second: needs request ID
  "auth",            # Third: authenticate before rate limiting
  "rate_limit",      # Fourth: rate limit authenticated requests
  "timeout",         # Fifth: apply timeout to business logic
  "error_handler",   # Near last: catch all errors
  "recovery"         # Last: ultimate safety net
])]
```

### Common Ordering Patterns

#### Standard Web Service
```crystal
@[Micro::Middleware([
  "request_id",
  "logging",
  "timing",
  "error_handler",
  "cors",
  "compression"
])]
```

#### Secured API
```crystal
@[Micro::Middleware([
  "request_id",
  "logging",
  "timing",
  "error_handler",
  "jwt_auth",
  "rate_limit",
  "request_size",
  "compression"
])]
```

#### Public API with Caching
```crystal
@[Micro::Middleware([
  "request_id",
  "logging",
  "timing",
  "error_handler",
  "cors",
  "rate_limit",
  "caching",
  "compression"
])]
```

## Advanced Patterns

### Conditional Middleware

Apply middleware based on conditions:

```crystal
class ConditionalAuthMiddleware
  include Micro::Core::Middleware
  
  def initialize(@public_methods : Array(String) = [] of String)
  end
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    method = context.request.endpoint
    
    # Skip auth for public methods
    if @public_methods.includes?(method)
      next_middleware.try(&.call(context))
      return
    end
    
    # Apply authentication
    authenticate(context)
    next_middleware.try(&.call(context))
  end
end
```

### Middleware Composition

Combine multiple middleware into one:

```crystal
class SecurityMiddleware
  include Micro::Core::Middleware
  
  def initialize
    @auth = JWTAuthMiddleware.new
    @rate_limit = RateLimitMiddleware.new(requests_per_minute: 60)
    @request_size = RequestSizeMiddleware.new(max_size: 5.megabytes)
  end
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    # Chain internal middleware
    @auth.call(context) do
      @rate_limit.call(context) do
        @request_size.call(context) do
          next_middleware.try(&.call(context))
        end
      end
    end
  end
end
```

### Dynamic Middleware Loading

Load middleware based on configuration:

```crystal
class DynamicMiddlewareLoader
  def self.load(names : Array(String), config : Hash(String, JSON::Any))
    names.map do |name|
      case name
      when "cors"
        CORSMiddleware.new(parse_cors_config(config["cors"]?))
      when "rate_limit"
        RateLimitMiddleware.new(parse_rate_config(config["rate_limit"]?))
      when "auth"
        load_auth_middleware(config["auth"]?)
      else
        # Load from registry
        MiddlewareRegistry.get(name).new
      end
    end
  end
end
```

### Middleware Communication

Share data between middleware via context:

```crystal
# First middleware sets data
class UserLoadMiddleware
  include Micro::Core::Middleware
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    if user_id = context.get?("user_id", String)
      user = load_user(user_id)
      context.set("user", user)
      context.set("user_roles", user.roles)
    end
    
    next_middleware.try(&.call(context))
  end
end

# Second middleware uses data
class RoleCheckMiddleware
  include Micro::Core::Middleware
  
  def initialize(@required_role : String)
  end
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    roles = context.get?("user_roles", Array(String)) || [] of String
    
    unless roles.includes?(@required_role)
      context.response.status = 403
      context.response.body = {error: "Insufficient permissions"}
      return
    end
    
    next_middleware.try(&.call(context))
  end
end
```

## Best Practices

### 1. Keep Middleware Focused

Each middleware should have a single responsibility:

```crystal
# Good: Focused on rate limiting
class RateLimitMiddleware
  include Micro::Core::Middleware
  
  def call(context, next_middleware)
    if rate_limit_exceeded?(context)
      reject_request(context)
    else
      next_middleware.try(&.call(context))
    end
  end
end

# Avoid: Doing too much
class KitchenSinkMiddleware
  def call(context, next_middleware)
    # Authenticate
    # Rate limit
    # Log
    # Cache
    # Transform
    # etc...
  end
end
```

### 2. Handle Errors Gracefully

Always consider error cases:

```crystal
class SafeMiddleware
  include Micro::Core::Middleware
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    begin
      # Your logic
      process_request(context)
    rescue ex : ExpectedException
      # Handle expected errors
      context.response.status = 400
      context.response.body = {error: ex.message}
      return
    rescue ex
      # Log unexpected errors but don't crash
      Log.error(exception: ex) { "Middleware error" }
      # Re-raise to let error handler deal with it
      raise ex
    end
    
    next_middleware.try(&.call(context))
  end
end
```

### 3. Make Middleware Configurable

Allow behavior customization:

```crystal
class ConfigurableMiddleware
  include Micro::Core::Middleware
  
  DEFAULT_TIMEOUT = 30.seconds
  DEFAULT_MAX_SIZE = 10.megabytes
  
  def initialize(timeout : Time::Span? = nil, 
                 max_size : Int32? = nil,
                 @strict_mode : Bool = false)
    @timeout = timeout || DEFAULT_TIMEOUT
    @max_size = max_size || DEFAULT_MAX_SIZE
  end
  
  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    # Use configuration
    if @strict_mode
      enforce_strict_rules(context)
    end
    
    # Continue...
  end
end
```

### 4. Document Middleware Behavior

Clear documentation helps users:

```crystal
# Tracks and enforces per-user quotas for API usage.
#
# This middleware integrates with the user service to track API calls
# and enforce quotas. It adds the following headers to responses:
# - X-Quota-Limit: User's quota limit
# - X-Quota-Remaining: Calls remaining
# - X-Quota-Reset: When quota resets (Unix timestamp)
#
# When quota is exceeded, returns 429 Too Many Requests with a
# Retry-After header indicating when the user can retry.
#
# Configuration:
# - check_interval: How often to sync quota (default: 1 minute)
# - hard_limit: Absolute max requests (default: 10000/hour)
# - quota_service: Service name for quota checks (default: "quotas")
class QuotaMiddleware
  include Micro::Core::Middleware
  # Implementation...
end
```

### 5. Test Middleware Thoroughly

Write comprehensive tests:

```crystal
describe CustomMiddleware do
  it "processes normal requests" do
    middleware = CustomMiddleware.new
    context = create_test_context
    called = false
    
    middleware.call(context) do
      called = true
    end
    
    called.should be_true
    context.response.headers["X-Custom"].should eq("processed")
  end
  
  it "handles errors gracefully" do
    middleware = CustomMiddleware.new
    context = create_test_context
    
    middleware.call(context) do
      raise "Test error"
    end
    
    context.response.status.should eq(500)
  end
  
  it "respects configuration" do
    middleware = CustomMiddleware.new(strict: true)
    context = create_invalid_context
    
    middleware.call(context) { }
    
    context.response.status.should eq(400)
  end
end
```

## Next Steps

- Explore [API Gateway](api-gateway.md) for gateway-specific middleware
- Learn about [Authentication & Security](auth-security.md) middleware
- Set up [Monitoring](monitoring.md) with metrics middleware
- Review [Testing](testing.md) strategies for middleware