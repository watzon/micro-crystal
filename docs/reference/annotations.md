# µCrystal Annotations Reference

## Table of contents

- [Service annotations](#service-annotations)
- [Method annotations](#method-annotations)
- [Middleware annotations](#middleware-annotations)
- [Authentication & authorization annotations](#authentication--authorization-annotations)
- [Handler configuration annotations](#handler-configuration-annotations)
- [OpenAPI documentation annotations](#openapi-documentation-annotations)
- [Usage guidelines](#usage-guidelines)
- [Common patterns](#common-patterns)

This document provides a complete reference for all annotations available in µCrystal. Annotations are used to configure services, methods, and behaviors at compile time.

## Service Annotations

### @[Micro::Service]

Marks a class as a microservice with service discovery metadata.

**Parameters:**
- `name` (String, required) - Service name for registration
- `version` (String) - Service version (default: "1.0.0")
- `namespace` (String?) - Optional namespace for grouping
- `description` (String?) - Optional service description
- `metadata` (Hash(String, String)?) - Optional key-value metadata
- `tags` (Array(String)?) - OpenAPI tags for grouping endpoints
- `contact` (Hash(String, String)?) - Contact info (name, email, url)
- `license` (Hash(String, String)?) - License info (name, url)
- `terms_of_service` (String?) - Terms of service URL
- `external_docs` (Hash(String, String)?) - External documentation (url, description)

**Example:**
```crystal
@[Micro::Service(
  name: "greeter",
  version: "1.0.0",
  namespace: "example",
  description: "A friendly greeting service",
  tags: ["greetings", "demo"],
  contact: {"name" => "API Support", "email" => "api@example.com"}
)]
class GreeterService
  include Micro::ServiceBase
end
```

**Related:** `@[Micro::Method]`, `@[Micro::Subscribe]`, `@[Micro::Middleware]`

## Method Annotations

### @[Micro::Method]

Marks a method as an RPC endpoint.

**Parameters:**
- `name` (String?) - Method name for RPC routing (defaults to method name)
- `description` (String?) - Method description
- `summary` (String?) - Short summary for documentation
- `timeout` (Int32?) - Request timeout in seconds
- `auth_required` (Bool) - Whether authentication is required (default: false)
- `deprecated` (Bool) - Mark as deprecated (default: false)
- `metadata` (Hash(String, String)?) - Optional metadata
- `request_example` (String?) - Example request body
- `response_examples` (Hash(String, String)?) - Example responses

**Example:**
```crystal
@[Micro::Method(
  name: "say_hello",
  summary: "Greet a user",
  description: "Returns a personalized greeting message",
  request_example: %({ "name": "World" }),
  response_examples: {"success" => %({ "message": "Hello World!" })}
)]
def hello(name : String) : String
  "Hello #{name}!"
end
```

**Related:** `@[Micro::Service]`, `@[Micro::AllowAnonymous]`, `@[Micro::RequireRole]`

### @[Micro::Subscribe]

Marks a method as a pub/sub event handler.

**Parameters:**
- `topic` (String, required) - Topic/channel to subscribe to
- `queue_group` (String?) - Optional queue group for load balancing
- `auto_ack` (Bool) - Auto-acknowledge messages (default: true)
- `max_retries` (Int32) - Max retries on failure (default: 3)
- `retry_backoff` (Int32) - Retry backoff in seconds (default: 5)
- `description` (String?) - Optional description
- `metadata` (Hash(String, String)?) - Optional metadata

**Example:**
```crystal
@[Micro::Subscribe(topic: "user.created", queue_group: "email-service")]
def handle_user_created(event : UserCreatedEvent)
  send_welcome_email(event.user)
end
```

**Related:** `@[Micro::Service]`, Broker configuration

## Middleware Annotations

### @[Micro::Middleware]

Applies middleware to a method or class.

**Parameters:**
- `names` (Array(String)) - List of middleware names to apply
- `options` (Hash(String, JSON::Any)?) - Middleware configuration

**Example:**
```crystal
# Class-level middleware
@[Micro::Middleware(["auth", "rate_limit"])]
class ProtectedService
  include Micro::ServiceBase
end

# Method-level middleware
@[Micro::Middleware(["logging"])]
def sensitive_operation
  # ...
end
```

**Related:** `@[Micro::SkipMiddleware]`, `@[Micro::RequireMiddleware]`, `@[Micro::MiddlewarePriority]`

### @[Micro::SkipMiddleware]

Skips specific middleware for a method.

**Parameters:**
- `names` (Array(String)) - List of middleware names to skip

**Example:**
```crystal
@[Micro::Middleware(["auth", "rate_limit"])]
class MyService
  @[Micro::SkipMiddleware(["rate_limit", "compression"])]
  def internal_method
    # This method skips rate limiting and compression
  end
end
```

**Related:** `@[Micro::Middleware]`, `@[Micro::RequireMiddleware]`

### @[Micro::RequireMiddleware]

Explicitly requires specific middleware for a method.

**Parameters:**
- `names` (Array(String)) - List of middleware names to require
- `priority` (Int32?) - Optional priority for ordering (higher runs first)

**Example:**
```crystal
@[Micro::RequireMiddleware(["admin_auth"], priority: 100)]
def admin_only_method
  # Ensures admin_auth middleware runs even if not in class middleware
end
```

**Related:** `@[Micro::Middleware]`, `@[Micro::SkipMiddleware]`

### @[Micro::MiddlewarePriority]

Sets middleware priority for ordering.

**Parameters:**
- `value` (Int32) - Priority value (higher values run first)

**Example:**
```crystal
@[Micro::Middleware(["logging"])]
@[Micro::MiddlewarePriority(1000)]
class MyService
  # Logging middleware will run with priority 1000
end
```

**Related:** `@[Micro::Middleware]`

## Authentication & Authorization Annotations

### @[Micro::AllowAnonymous]

Allows anonymous access to a method, bypassing authentication middleware.

**Parameters:** None

**Example:**
```crystal
@[Micro::Service(name: "api")]
@[Micro::Middleware(["auth"])]
class ApiService
  @[Micro::Method]
  @[Micro::AllowAnonymous]
  def health_check : String
    "OK"
  end
end
```

**Related:** `@[Micro::RequireRole]`, `@[Micro::RequirePermission]`

### @[Micro::RequireRole]

Requires specific roles to access a method or service.

**Parameters:**
- `roles` (Array(String) | String) - Required role(s)
- `require_all` (Bool) - Whether all roles are required (default: false)

**Example:**
```crystal
@[Micro::RequireRole("admin")]
def admin_action
  # Only users with admin role can access
end

@[Micro::RequireRole(["admin", "manager"], require_all: true)]
def restricted_action
  # Requires both admin AND manager roles
end
```

**Related:** `@[Micro::RequirePermission]`, `@[Micro::RequirePolicy]`

### @[Micro::RequirePermission]

Requires specific permissions to access a method or service.

**Parameters:**
- `permissions` (Array(String) | String) - Required permission(s) in "resource:action:scope" format
- `require_all` (Bool) - Whether all permissions are required (default: true)

**Example:**
```crystal
@[Micro::RequirePermission("users:write")]
def create_user
  # Requires users:write permission
end

@[Micro::RequirePermission(["users:read", "users:write"], require_all: false)]
def user_operation
  # Requires either users:read OR users:write
end
```

**Related:** `@[Micro::RequireRole]`, `@[Micro::RequirePolicy]`

### @[Micro::RequirePolicy]

Defines a custom authorization policy for a method.

**Parameters:**
- `policy` (String) - Name of the policy class to use
- `params` (Hash(String, JSON::Any)?) - Optional parameters for the policy

**Example:**
```crystal
@[Micro::RequirePolicy("OwnershipPolicy", params: {"resource" => "user"})]
def update_profile
  # Uses custom OwnershipPolicy to check authorization
end
```

**Related:** `@[Micro::RequireRole]`, `@[Micro::RequirePermission]`

## Handler Configuration Annotations

### @[Micro::Handler]

Configures custom handler behavior.

**Parameters:**
- `streaming` (Bool) - Enable streaming support (default: false)
- `max_message_size` (Int32?) - Maximum message size in bytes
- `codec` (String?) - Custom codec (overrides service default)
- `compress` (Bool) - Enable response compression (default: false)
- `error_handler` (String?) - Custom error handler method name
- `options` (Hash(String, JSON::Any)?) - Additional handler options

**Example:**
```crystal
@[Micro::Handler(streaming: true, max_message_size: 1048576)]
def stream_data(request : StreamRequest)
  # Handles streaming with 1MB max message size
end
```

**Related:** `@[Micro::Method]`

## OpenAPI Documentation Annotations

### @[Micro::Param]

Documents a method parameter for OpenAPI generation.

**Parameters:**
- `name` (String) - Parameter name
- `description` (String?) - Parameter description
- `required` (Bool) - Whether parameter is required (default: true)
- `example` (String?) - Example value
- `format` (String?) - Data format (email, uuid, date-time, etc.)
- `pattern` (String?) - Regex pattern for validation
- `minimum` (Number?) - Minimum value for numbers
- `maximum` (Number?) - Maximum value for numbers
- `enum` (Array(String)?) - Allowed values

**Example:**
```crystal
@[Micro::Method]
def get_user(
  @[Micro::Param(
    name: "user_id",
    description: "Unique user identifier",
    format: "uuid",
    example: "123e4567-e89b-12d3-a456-426614174000"
  )]
  user_id : String
) : User
  # ...
end
```

**Related:** `@[Micro::Response]`, `@[Micro::Schema]`

### @[Micro::Response]

Documents a method response for OpenAPI generation.

**Parameters:**
- `status` (Int32) - HTTP status code (default: 200)
- `description` (String) - Response description
- `schema` (String?) - Response schema type name
- `example` (String?) - Example response
- `headers` (Hash(String, String)?) - Response headers

**Example:**
```crystal
@[Micro::Response(
  status: 200,
  description: "User created successfully",
  schema: "UserResponse",
  example: %({ "id": "123", "name": "John" })
)]
@[Micro::Response(
  status: 404,
  description: "User not found"
)]
def create_user(data : UserData) : UserResponse
  # ...
end
```

**Related:** `@[Micro::Param]`, `@[Micro::Schema]`

### @[Micro::Schema]

Marks a type to be included in OpenAPI schemas.

**Parameters:**
- `name` (String?) - Schema name (defaults to type name)
- `description` (String?) - Schema description
- `example` (String?) - Example instance

**Example:**
```crystal
@[Micro::Schema(
  description: "User profile information",
  example: %({ "id": "123", "name": "John", "email": "john@example.com" })
)]
struct UserProfile
  @[Micro::Field(validate: {required: true})]
  property id : String

  @[Micro::Field(validate: {required: true, min_length: 2})]
  property name : String

  @[Micro::Field(validate: {required: true, matches: /^[^@]+@[^@]+\.[^@]+$/})]
  property email : String
end
```

**Related:** `@[Micro::Field]`, `@[Micro::Response]`

### @[Micro::Field]

Field-level metadata and validation for schema properties.

**Parameters:**
- `description` (String?) - Field description
- `example` (String?) - Example value
- `validate` (NamedTuple?) - Validation rules

**Validation rules:**
- `required` (Bool) - Whether field is required
- `min_length` (Int32) - Minimum string length
- `max_length` (Int32) - Maximum string length
- `min_value` (Number) - Minimum numeric value
- `max_value` (Number) - Maximum numeric value
- `matches` (Regex) - Pattern to match
- `enum` (Array) - Allowed values
- `custom` (String) - Name of custom validator method

**Example:**
```crystal
@[Micro::Field(
  description: "User's email address",
  example: "user@example.com",
  validate: {
    required: true,
    matches: /^[^@]+@[^@]+\.[^@]+$/,
  }
)]
property email : String
```

**Related:** `@[Micro::Schema]`

### @[Micro::Tag]

Groups related API operations.

**Parameters:**
- `name` (String) - Tag name
- `description` (String?) - Tag description
- `external_docs` (Hash(String, String)?) - External documentation

**Example:**
```crystal
@[Micro::Tag(
  name: "users",
  description: "User management operations"
)]
class UserService
  # All methods in this service will be tagged as "users"
end
```

**Related:** `@[Micro::Service]`

### @[Micro::Security]

Defines security requirements for a method or service.

**Parameters:**
- `type` (String) - Security type (bearer, apiKey, oauth2, openIdConnect)
- `scopes` (Array(String)?) - Required OAuth2 scopes
- `description` (String?) - Security description

**Example:**
```crystal
@[Micro::Security(type: "bearer")]
class SecureService
  # All methods require bearer token
end

@[Micro::Security(type: "oauth2", scopes: ["read:users", "write:users"])]
def manage_users
  # Requires OAuth2 with specific scopes
end
```

**Related:** `@[Micro::RequireRole]`, `@[Micro::AllowAnonymous]`

## Usage Guidelines

1. **Service-level annotations** should be placed on the class declaration
2. **Method-level annotations** override service-level settings
3. **Multiple annotations** can be combined on the same element
4. **Validation annotations** work with the built-in validation system
5. **OpenAPI annotations** are used for automatic documentation generation

## Common Patterns

### Protected Service with Public Health Check
```crystal
@[Micro::Service(name: "protected-api")]
@[Micro::Middleware(["auth", "rate_limit"])]
class ProtectedAPI
  include Micro::ServiceBase

  @[Micro::Method]
  @[Micro::AllowAnonymous]
  @[Micro::SkipMiddleware(["rate_limit"])]
  def health : String
    "OK"
  end

  @[Micro::Method]
  @[Micro::RequireRole("admin")]
  def admin_operation
    # Protected by auth middleware + admin role
  end
end
```

### Event-Driven Service
```crystal
@[Micro::Service(name: "event-processor")]
class EventProcessor
  include Micro::ServiceBase

  @[Micro::Subscribe(topic: "orders.created", queue_group: "processors")]
  def handle_order_created(order : Order)
    # Process new orders
  end

  @[Micro::Subscribe(topic: "orders.cancelled")]
  def handle_order_cancelled(order_id : String)
    # Handle cancellations
  end
end
```

### Well-Documented API
```crystal
@[Micro::Service(
  name: "user-api",
  description: "User management service",
  tags: ["users", "authentication"]
)]
@[Micro::Tag(name: "users", description: "User CRUD operations")]
class UserAPI
  include Micro::ServiceBase

  @[Micro::Method(
    summary: "Create a new user",
    description: "Creates a new user account with the provided information"
  )]
  @[Micro::Response(status: 201, description: "User created", schema: "User")]
  @[Micro::Response(status: 400, description: "Invalid input")]
  def create_user(
    @[Micro::Param(description: "User creation data")]
    data : UserCreateRequest
  ) : User
    # Implementation
  end
end
```