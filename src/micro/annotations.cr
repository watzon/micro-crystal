# Annotations for micro-crystal framework
# These annotations provide metadata for services, methods, and handlers
# that will be processed by macros to generate boilerplate code

module Micro
  # Marks a class as a microservice with service discovery metadata
  #
  # Available fields:
  # - name : String (required) - Service name for registration
  # - version : String - Service version (default: "1.0.0")
  # - namespace : String? - Optional namespace for grouping
  # - description : String? - Optional service description
  # - metadata : Hash(String, String)? - Optional key-value metadata
  # - tags : Array(String)? - OpenAPI tags for grouping endpoints
  # - contact : Hash(String, String)? - Contact info (name, email, url)
  # - license : Hash(String, String)? - License info (name, url)
  # - terms_of_service : String? - Terms of service URL
  # - external_docs : Hash(String, String)? - External documentation (url, description)
  #
  # Example:
  # ```
  # @[Micro::Service(
  #   name: "greeter",
  #   version: "1.0.0",
  #   namespace: "example",
  #   description: "A friendly greeting service",
  #   tags: ["greetings", "demo"],
  #   contact: {"name" => "API Support", "email" => "api@example.com"}
  # )]
  # class GreeterService
  # end
  # ```
  annotation Service
  end

  # Marks a method as an RPC endpoint
  #
  # Available fields for RPC/Service concerns:
  # - name : String? - Method name for RPC routing (defaults to method name)
  # - description : String? - Method description
  # - summary : String? - Short summary for documentation
  # - timeout : Int32? - Request timeout in seconds
  # - auth_required : Bool - Whether authentication is required (default: false)
  # - deprecated : Bool - Mark as deprecated (default: false)
  # - metadata : Hash(String, String)? - Optional metadata
  # - request_example : String? - Example request body
  # - response_examples : Hash(String, String)? - Example responses
  #
  # Note: HTTP-specific routing (path, http_method) should be configured
  # in the API Gateway route configuration, not here.
  #
  # Example:
  # ```
  # @[Micro::Method(
  #   name: "say_hello",
  #   summary: "Greet a user",
  #   description: "Returns a personalized greeting message",
  #   request_example: %({ "name": "World" }),
  #   response_examples: {"success" => %({ "message": "Hello World!" })}
  # )]
  # def hello(name : String) : String
  #   "Hello #{name}!"
  # end
  # ```
  annotation Method
  end

  # Marks a method as a pub/sub event handler
  #
  # Available fields:
  # - topic : String (required) - Topic/channel to subscribe to
  # - queue_group : String? - Optional queue group for load balancing
  # - auto_ack : Bool - Auto-acknowledge messages (default: true)
  # - max_retries : Int32 - Max retries on failure (default: 3)
  # - retry_backoff : Int32 - Retry backoff in seconds (default: 5)
  # - description : String? - Optional description
  # - metadata : Hash(String, String)? - Optional metadata
  #
  # Example:
  # ```
  # @[Micro::Subscribe(topic: "user.created", queue_group: "email-service")]
  # def handle_user_created(event : UserCreatedEvent)
  #   send_welcome_email(event.user)
  # end
  # ```
  annotation Subscribe
  end

  # Applies middleware to a method or class
  #
  # Takes a single argument:
  # - names : Array(String) - List of middleware names to apply
  #
  # Or with options:
  # - names : Array(String) - List of middleware names
  # - options : Hash(String, JSON::Any)? - Middleware configuration
  #
  # Example:
  # ```
  # @[Micro::Middleware(["auth", "rate_limit"])]
  # def protected_method
  # end
  # ```
  annotation Middleware
  end

  # Configures custom handler behavior
  #
  # Available fields:
  # - streaming : Bool - Enable streaming support (default: false)
  # - max_message_size : Int32? - Maximum message size in bytes
  # - codec : String? - Custom codec (overrides service default)
  # - compress : Bool - Enable response compression (default: false)
  # - error_handler : String? - Custom error handler method name
  # - options : Hash(String, JSON::Any)? - Additional handler options
  #
  # Example:
  # ```
  # @[Micro::Handler(streaming: true, max_message_size: 1048576)]
  # def stream_data(request : StreamRequest)
  # end
  # ```
  annotation Handler
  end

  # Allows anonymous access to a method, bypassing authentication middleware
  #
  # This annotation tells the middleware chain to skip any authentication
  # or authorization checks for the annotated method, even if the service
  # itself requires authentication.
  #
  # Example:
  # ```
  # @[Micro::Service(name: "api")]
  # @[Micro::Middleware(["auth"])]
  # class ApiService
  #   @[Micro::Method]
  #   @[Micro::AllowAnonymous]
  #   def health_check : String
  #     "OK"
  #   end
  # end
  # ```
  annotation AllowAnonymous
  end

  # Skips specific middleware for a method
  #
  # Takes a single argument:
  # - names : Array(String) - List of middleware names to skip
  #
  # Example:
  # ```
  # @[Micro::SkipMiddleware(["rate_limit", "compression"])]
  # def internal_method
  # end
  # ```
  annotation SkipMiddleware
  end

  # Explicitly requires specific middleware for a method
  #
  # Takes arguments:
  # - names : Array(String) - List of middleware names to require
  # - priority : Int32? - Optional priority for ordering (higher runs first)
  #
  # Example:
  # ```
  # @[Micro::RequireMiddleware(["admin_auth"], priority: 100)]
  # def admin_only_method
  # end
  # ```
  annotation RequireMiddleware
  end

  # Sets middleware priority for ordering
  #
  # Takes a single argument:
  # - value : Int32 - Priority value (higher values run first)
  #
  # Example:
  # ```
  # @[Micro::Middleware(["logging"])]
  # @[Micro::MiddlewarePriority(1000)]
  # class MyService
  # end
  # ```
  annotation MiddlewarePriority
  end

  # Requires specific roles to access a method or service
  #
  # Takes arguments:
  # - roles : Array(String) | String - Required role(s)
  # - require_all : Bool - Whether all roles are required (default: false)
  #
  # Example:
  # ```
  # @[Micro::RequireRole("admin")]
  # def admin_action
  # end
  #
  # @[Micro::RequireRole(["admin", "manager"], require_all: true)]
  # def restricted_action
  # end
  # ```
  annotation RequireRole
  end

  # Requires specific permissions to access a method or service
  #
  # Takes arguments:
  # - permissions : Array(String) | String - Required permission(s) in "resource:action:scope" format
  # - require_all : Bool - Whether all permissions are required (default: true)
  #
  # Example:
  # ```
  # @[Micro::RequirePermission("users:write")]
  # def create_user
  # end
  #
  # @[Micro::RequirePermission(["users:read", "users:write"], require_all: false)]
  # def user_operation
  # end
  # ```
  annotation RequirePermission
  end

  # Defines a custom authorization policy for a method
  #
  # Takes arguments:
  # - policy : String - Name of the policy class to use
  # - params : Hash(String, JSON::Any)? - Optional parameters for the policy
  #
  # Example:
  # ```
  # @[Micro::RequirePolicy("OwnershipPolicy", params: {"resource" => "user"})]
  # def update_profile
  # end
  # ```
  annotation RequirePolicy
  end

  # Apply rate limiting to methods
  #
  # Takes arguments:
  # - requests : Int32 - Number of requests allowed per time period
  # - per : Int32 - Time period in seconds
  # - key : String? - Rate limit key strategy (default: "ip", options: "ip", "user", "custom")
  # - burst : Int32? - Optional burst allowance
  #
  # Example:
  # ```
  # @[Micro::RateLimit(requests: 100, per: 60)] # 100 requests per minute
  # def search_products(query : String) : Array(Product)
  #   # Search implementation
  # end
  #
  # @[Micro::RateLimit(requests: 10, per: 60, burst: 5)] # 10/min with burst of 5
  # def heavy_operation
  # end
  # ```
  annotation RateLimit
  end

  # Documents a method parameter for OpenAPI generation
  #
  # Available fields:
  # - name : String - Parameter name
  # - description : String? - Parameter description
  # - required : Bool - Whether parameter is required (default: true)
  # - example : String? - Example value
  # - format : String? - Data format (email, uuid, date-time, etc.)
  # - pattern : String? - Regex pattern for validation
  # - minimum : Number? - Minimum value for numbers
  # - maximum : Number? - Maximum value for numbers
  # - enum : Array(String)? - Allowed values
  #
  # Example:
  # ```
  # @[Micro::Param(
  #   name: "user_id",
  #   description: "Unique user identifier",
  #   format: "uuid",
  #   example: "123e4567-e89b-12d3-a456-426614174000"
  # )]
  # ```
  annotation Param
  end

  # Documents a method response for OpenAPI generation
  #
  # Available fields:
  # - status : Int32 - HTTP status code (default: 200)
  # - description : String - Response description
  # - schema : String? - Response schema type name
  # - example : String? - Example response
  # - headers : Hash(String, String)? - Response headers
  #
  # Example:
  # ```
  # @[Micro::Response(
  #   status: 200,
  #   description: "User created successfully",
  #   schema: "UserResponse",
  #   example: %({ "id": "123", "name": "John" })
  # )]
  # @[Micro::Response(
  #   status: 404,
  #   description: "User not found"
  # )]
  # ```
  annotation Response
  end

  # Marks a type to be included in OpenAPI schemas
  #
  # Available fields:
  # - name : String? - Schema name (defaults to type name)
  # - description : String? - Schema description
  # - example : String? - Example instance
  #
  # Example:
  # ```
  # @[Micro::Schema(
  #   description: "User profile information",
  #   example: %({ "id": "123", "name": "John", "email": "john@example.com" })
  # )]
  # struct UserProfile
  #   @[Micro::Field(validate: {required: true})]
  #   property id : String
  #
  #   @[Micro::Field(validate: {required: true, min_length: 2})]
  #   property name : String
  #
  #   @[Micro::Field(validate: {required: true, matches: /^[^@]+@[^@]+\.[^@]+$/})]
  #   property email : String
  # end
  # ```
  annotation Schema
  end

  # Field-level metadata and validation for schema properties
  #
  # Available fields:
  # - description : String? - Field description
  # - example : String? - Example value
  # - validate : NamedTuple? - Validation rules
  #
  # Validation rules:
  # - required : Bool - Whether field is required
  # - min_length : Int32 - Minimum string length
  # - max_length : Int32 - Maximum string length
  # - min_value : Number - Minimum numeric value
  # - max_value : Number - Maximum numeric value
  # - matches : Regex - Pattern to match
  # - enum : Array - Allowed values
  # - custom : String - Name of custom validator method
  #
  # Example:
  # ```
  # @[Micro::Field(
  #   description: "User's email address",
  #   example: "user@example.com",
  #   validate: {
  #     required: true,
  #     matches:  /^[^@]+@[^@]+\.[^@]+$/,
  #   }
  # )]
  # property email : String
  # ```
  annotation Field
  end

  # Groups related API operations
  #
  # Available fields:
  # - name : String - Tag name
  # - description : String? - Tag description
  # - external_docs : Hash(String, String)? - External documentation
  #
  # Example:
  # ```
  # @[Micro::Tag(
  #   name: "users",
  #   description: "User management operations"
  # )]
  # ```
  annotation Tag
  end

  # Defines security requirements for a method or service
  #
  # Available fields:
  # - type : String - Security type (bearer, apiKey, oauth2, openIdConnect)
  # - scopes : Array(String)? - Required OAuth2 scopes
  # - description : String? - Security description
  #
  # Example:
  # ```
  # @[Micro::Security(type: "bearer")]
  # @[Micro::Security(type: "oauth2", scopes: ["read:users", "write:users"])]
  # ```
  annotation Security
  end
end
