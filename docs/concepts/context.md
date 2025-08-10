# Context

## Table of contents

- [Key concepts](#key-concepts)
- [Creating context](#creating-context)
- [Propagating values](#propagating-values)
- [Error handling](#error-handling)
- [Context patterns](#context-patterns)
- [Best practices](#best-practices)
- [Related concepts](#related-concepts)

Context carries request and response information through the service method lifecycle. It provides a way to pass data between middleware and handlers, and manages request/response state.

## Key concepts

### Request lifecycle
Every service method receives a context as its first parameter. This context travels with the request through middleware, handlers, and across service calls.

### Request and response
Context contains the incoming request with headers, body, and metadata, plus the response being built.

### Attribute storage
Context provides typed attribute storage for middleware to pass data to handlers and between middleware layers.

## Creating context

### In service handlers

Service methods receive context automatically:

```crystal
@[Micro::Service(name: "api")]
class APIService
  include Micro::ServiceBase
  
  @[Micro::Method]
  def process(ctx : Micro::Core::Context, req : Request) : Response
    # Context is provided by the framework
    # Access request information
    service = ctx.request.service
    endpoint = ctx.request.endpoint
    
    # Get header values
    request_id = ctx.request.headers["X-Request-ID"]?
    
    # Set response headers
    ctx.response.headers["X-Request-ID"] = request_id || UUID.random.to_s
    
    Response.new(id: request_id)
  end
end
```

### For testing

Create context for testing:

```crystal
# Create a test context
ctx = Micro::Core::Context.background

# Set request headers
ctx.request.headers["X-User-ID"] = "test-user"

# Call handler directly
response = handler(ctx, request)
```

## Propagating values

### Through attributes

Use typed attributes to pass data between middleware and handlers:

```crystal
@[Micro::Service(name: "api")]
class APIService
  include Micro::ServiceBase
  
  @[Micro::Method]
  def handle_request(ctx : Micro::Core::Context, req : Request) : Response
    # Get user set by auth middleware
    user = ctx.get!("user", User)
    
    # Set data for later middleware
    ctx.set("processed_at", Time.utc)
    
    Response.new(user_id: user.id)
  end
end
```

### Through middleware

Middleware can add values to context:

```crystal
class AuthenticationMiddleware
  include Micro::Core::Middleware
  
  def call(ctx : Micro::Core::Context, next : Micro::Core::Next) : Nil
    # Extract auth token from headers
    token = ctx.request.headers["Authorization"]?
    
    if token && user = validate_token(token)
      # Add user to context attributes
      ctx.set("user", user)
      ctx.set("authenticated", true)
      
      # Continue with enriched context
      next.call(ctx)
    else
      ctx.response.status = 401
      ctx.response.body = {"error" => "Unauthorized"}
    end
  end
end
```

## Error handling

### Setting errors

Context can track errors that occur during processing:

```crystal
@[Micro::Method]
def risky_operation(ctx : Micro::Core::Context, req : Request) : Response
  begin
    result = perform_risky_operation(req)
    Response.new(result: result)
  rescue ex
    # Set error on context
    ctx.set_error(ex)
    # Response status and body are set automatically
    ctx.response
  end
end
```

### Checking for errors

Middleware can check if an error occurred:

```crystal
class ErrorLoggingMiddleware
  include Micro::Core::Middleware
  
  def call(ctx : Micro::Core::Context, next : Micro::Core::Next) : Nil
    next.call(ctx)
  ensure
    if ctx.error?
      Log.error(exception: ctx.error) { "Request failed" }
    end
  end
end
```

## Context patterns

### Request ID tracking

Track requests across services:

```crystal
class RequestIDMiddleware
  include Micro::Core::Middleware
  
  def call(ctx : Micro::Core::Context, next : Micro::Core::Next) : Nil
    # Get or generate request ID
    request_id = ctx.request.headers["X-Request-ID"]? || UUID.random.to_s
    
    # Add to context attributes
    ctx.set("request-id", request_id)
    
    # Add to logs
    Log.context.set(request_id: request_id)
    
    # Call next handler
    next.call(ctx)
    
    # Add to response headers
    ctx.response.headers["X-Request-ID"] = request_id
  ensure
    Log.context.clear
  end
end
```

### User context

Propagate user information:

```crystal
class UserContextMiddleware
  include Micro::Core::Middleware
  
  def call(ctx : Micro::Core::Context, next : Micro::Core::Next) : Nil
    if user_id = ctx.request.headers["X-User-ID"]?
      # Load user data
      user = User.find(user_id)
      
      # Add to context attributes
      ctx.set("user", user)
      ctx.set("tenant-id", user.tenant_id)
      ctx.set("permissions", user.permissions)
    end
    
    next.call(ctx)
  end
end

# Use in handlers
@[Micro::Method]
def get_data(ctx : Micro::Core::Context, req : Request) : Response
  user = ctx.get!("user", User)
  permissions = ctx.get!("permissions", Array(String))
  
  unless permissions.includes?("read:data")
    raise Micro::Core::Error.new(code: 403, detail: "Forbidden")
  end
  
  Response.new(data: load_data_for_user(user))
end
```

### Distributed tracing

Propagate trace context:

```crystal
class TracingMiddleware
  include Micro::Core::Middleware
  
  def call(ctx : Micro::Core::Context, next : Micro::Core::Next) : Nil
    # Extract trace context from headers
    trace_id = ctx.request.headers["X-Trace-ID"]? || generate_trace_id
    span_id = generate_span_id
    parent_span = ctx.request.headers["X-Span-ID"]?
    
    # Create span
    span = Span.new(
      trace_id: trace_id,
      span_id: span_id,
      parent_id: parent_span,
      operation: "#{ctx.request.service}.#{ctx.request.endpoint}"
    )
    
    # Add to context attributes
    ctx.set("trace-id", trace_id)
    ctx.set("span-id", span_id)
    ctx.set("span", span)
    
    # Add to response headers for propagation
    ctx.response.headers["X-Trace-ID"] = trace_id
    ctx.response.headers["X-Span-ID"] = span_id
    
    begin
      next.call(ctx)
      span.set_status(:ok)
    rescue ex
      span.set_status(:error)
      span.add_event("exception", {
        "exception.type" => ex.class.name,
        "exception.message" => ex.message
      })
      raise ex
    ensure
      span.finish
    end
  end
end
```

## Best practices

### Use typed attributes
Context attributes are type-safe. Always specify the type when getting:

```crystal
# Good - specify type
user = ctx.get("user", User)
authenticated = ctx.get("authenticated", Bool) || false

# Better - use get! if value must exist
user = ctx.get!("user", User)

# Bad - don't assume types
# user = ctx.get("user")  # Won't compile
```

### Avoid large values
Context should carry metadata, not large payloads:

```crystal
# Good - store reference
ctx = ctx.with_value("file-id", "abc123")

# Bad - don't store large data
# ctx = ctx.with_value("file-content", file_bytes)  # Too large
```

### Create helper methods
Create helper methods for common context operations:

```crystal
# Extension methods for common attributes
class Micro::Core::Context
  def user : User?
    get("user", User)
  end
  
  def authenticated? : Bool
    get("authenticated", Bool) || false
  end
  
  def request_id : String?
    get("request-id", String)
  end
  
  def tenant_id : String?
    get("tenant-id", String)
  end
end

# Use in handlers
@[Micro::Method]
def get_profile(ctx : Micro::Core::Context, req : Request) : Response
  unless ctx.authenticated?
    raise Micro::Core::Error.new(code: 401, detail: "Not authenticated")
  end
  
  if user = ctx.user
    Response.new(profile: user.profile)
  else
    raise Micro::Core::Error.new(code: 401, detail: "User not found")
  end
end
```

## Related concepts

- [Services](services.md) - How services receive and use context
- [Transport](transport.md) - Context propagation over the wire
- [Registry](registry.md) - Service metadata in context
- [Broker](broker.md) - Event context in pub/sub
- [Codecs](codecs.md) - Encoding context for transport