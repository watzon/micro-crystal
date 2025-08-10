# Basic service patterns

## Table of contents

- [Hello world walkthrough](#hello-world-walkthrough)
- [Adding middleware](#adding-middleware)
- [Service with multiple methods](#service-with-multiple-methods)
- [Error handling](#error-handling)
- [Next steps](#next-steps)

This guide walks through fundamental µCrystal service patterns, starting with simple examples and progressively adding complexity.

## Hello world walkthrough

The simplest µCrystal service demonstrates the core concepts: service annotation, method exposure, and running the service.

```crystal
require "micro"

@[Micro::Service(name: "hello-service", version: "1.0.0")]
class HelloService
  include Micro::ServiceBase

  @[Micro::Method(description: "Say hello")]
  def hello(name : String) : String
    "Hello, #{name}!"
  end
end

# Run the service
HelloService.run
```

This example introduces several key concepts:

1. **Service annotation**: The `@[Micro::Service]` annotation defines service metadata. The name becomes the service identifier in the registry, and version helps with service evolution.

2. **ServiceBase inclusion**: `include Micro::ServiceBase` provides all the machinery needed for a functioning service - transport handling, codec negotiation, lifecycle management, and more.

3. **Method annotation**: `@[Micro::Method]` marks a method as remotely callable. The framework automatically handles serialization, deserialization, and transport.

4. **Type safety**: Crystal's type system ensures that method signatures are enforced at compile time, catching errors before deployment.

The service automatically:
- Starts an HTTP server on port 8080 (configurable via `MICRO_SERVER_ADDRESS`)
- Registers with the configured registry (defaults to in-memory for development)
- Handles JSON serialization/deserialization (with automatic codec negotiation)
- Provides health checks and graceful shutdown

## Adding middleware

Middleware provides cross-cutting concerns like logging, authentication, and error handling. µCrystal uses an annotation-based approach for clean, declarative configuration.

```crystal
require "micro"

@[Micro::Service(name: "protected", version: "1.0.0")]
@[Micro::Middleware([
  "request_id",       # Generates/propagates request IDs
  "logging",          # Structured request/response logging
  "timing",           # Tracks request duration
  "error_handler",    # Converts exceptions to proper responses
  "auth",             # JWT authentication
  "rate_limit"        # Request rate limiting
])]
class ProtectedService
  include Micro::ServiceBase

  # Public endpoint - bypasses auth middleware
  @[Micro::Method]
  @[Micro::AllowAnonymous]
  def health_check : String
    "OK"
  end

  # Protected endpoint - requires valid JWT
  @[Micro::Method]
  def get_user_data(user_id : String) : UserData
    # The auth middleware ensures we have a valid user context here
    current_user = context.get!("user_id", String)
    
    # Verify the user can access this data
    unless current_user == user_id || is_admin?(current_user)
      raise UnauthorizedError.new("Cannot access other user's data")
    end
    
    fetch_user_data(user_id)
  end

  # Role-based access control
  @[Micro::Method]
  @[Micro::RequireRole("admin")]
  def delete_user(user_id : String) : Bool
    # Only admins can reach this method
    delete_user_from_database(user_id)
  end
end
```

The middleware pipeline executes in order, allowing each middleware to:
- Inspect and modify the request
- Short-circuit the request (e.g., auth failures)
- Wrap the handler execution (e.g., timing, error recovery)
- Modify the response

Key middleware concepts:

1. **Request ID propagation**: Essential for distributed tracing. The request ID flows through all service calls, enabling end-to-end request tracking.

2. **Structured logging**: The logging middleware captures request details, timing, and outcomes in a format suitable for log aggregation systems.

3. **Error handling**: The error handler middleware ensures that exceptions are converted to appropriate HTTP responses with proper status codes.

4. **Authentication bypass**: The `@[Micro::AllowAnonymous]` annotation allows specific methods to bypass authentication, useful for health checks and public endpoints.

## Service with multiple methods

Real services expose multiple related operations. Here's a more complete example showing common patterns:

```crystal
require "micro"
require "uuid"

@[Micro::Service(name: "tasks", version: "1.0.0")]
@[Micro::Middleware(["request_id", "logging", "timing", "error_handler"])]
class TaskService
  include Micro::ServiceBase

  struct Task
    include JSON::Serializable
    
    getter id : String
    getter title : String
    getter description : String
    getter completed : Bool
    getter created_at : Time
    getter updated_at : Time
    
    def initialize(@title : String, @description : String)
      @id = UUID.random.to_s
      @completed = false
      @created_at = Time.utc
      @updated_at = Time.utc
    end
  end

  struct CreateTaskRequest
    include JSON::Serializable
    getter title : String
    getter description : String
  end

  struct UpdateTaskRequest
    include JSON::Serializable
    getter title : String?
    getter description : String?
    getter completed : Bool?
  end

  # In-memory storage for demo (use a real database in production)
  @@tasks = {} of String => Task

  # Create a new task
  @[Micro::Method]
  def create_task(request : CreateTaskRequest) : Task
    task = Task.new(request.title, request.description)
    @@tasks[task.id] = task
    
    # Publish event for other services
    publish("tasks.created", {
      task_id: task.id,
      title: task.title
    })
    
    task
  end

  # List all tasks with optional filtering
  @[Micro::Method]
  def list_tasks(completed : Bool? = nil) : Array(Task)
    tasks = @@tasks.values
    
    if completed_filter = completed
      tasks = tasks.select { |t| t.completed == completed_filter }
    end
    
    tasks.sort_by(&.created_at).reverse
  end

  # Get a specific task
  @[Micro::Method]
  def get_task(id : String) : Task?
    @@tasks[id]?
  end

  # Update an existing task
  @[Micro::Method]
  def update_task(id : String, request : UpdateTaskRequest) : Task
    task = @@tasks[id]? || raise ArgumentError.new("Task not found")
    
    # Create a mutable copy with updates
    updated = Task.new(
      request.title || task.title,
      request.description || task.description
    )
    updated.id = task.id
    updated.completed = request.completed || task.completed
    updated.created_at = task.created_at
    updated.updated_at = Time.utc
    
    @@tasks[id] = updated
    
    # Publish event for other services
    if request.completed && !task.completed
      publish("tasks.completed", {
        task_id: id,
        title: updated.title
      })
    end
    
    updated
  end

  # Delete a task
  @[Micro::Method]
  def delete_task(id : String) : Bool
    if task = @@tasks.delete(id)
      publish("tasks.deleted", {
        task_id: id,
        title: task.title
      })
      true
    else
      false
    end
  end

  # Batch operations for efficiency
  @[Micro::Method]
  def delete_completed_tasks : Int32
    completed_tasks = @@tasks.values.select(&.completed)
    count = completed_tasks.size
    
    completed_tasks.each do |task|
      @@tasks.delete(task.id)
    end
    
    if count > 0
      publish("tasks.bulk_deleted", {
        count: count,
        task_type: "completed"
      })
    end
    
    count
  end
end
```

This example demonstrates several important patterns:

1. **Structured data types**: Using Crystal structs with `JSON::Serializable` provides automatic serialization while maintaining type safety.

2. **Request/response separation**: Separate types for requests allow for partial updates and clear API contracts.

3. **Event publishing**: Services can publish events about state changes, enabling event-driven architectures.

4. **Batch operations**: Providing batch endpoints reduces network overhead for bulk operations.

5. **Nullable parameters**: Optional parameters with defaults make APIs more flexible.

## Error handling

Proper error handling is crucial for production services. µCrystal provides several mechanisms for consistent error management:

```crystal
require "micro"

# Define custom error types for clear error semantics
class ValidationError < Exception
  getter field : String
  getter code : String
  
  def initialize(@field : String, @code : String, message : String)
    super(message)
  end
end

class NotFoundError < Exception
  getter resource : String
  getter id : String
  
  def initialize(@resource : String, @id : String)
    super("#{resource} with id #{id} not found")
  end
end

class BusinessLogicError < Exception
  getter error_code : String
  
  def initialize(@error_code : String, message : String)
    super(message)
  end
end

@[Micro::Service(name: "orders", version: "1.0.0")]
@[Micro::Middleware([
  "request_id", 
  "logging", 
  "timing", 
  "error_handler",  # Converts exceptions to proper HTTP responses
  "recovery"        # Prevents panics from crashing the service
])]
class OrderService
  include Micro::ServiceBase

  struct Order
    include JSON::Serializable
    getter id : String
    getter user_id : String
    getter total : Float64
    getter status : String
  end

  # Demonstrates validation errors
  @[Micro::Method]
  def create_order(user_id : String, amount : Float64) : Order
    # Validate inputs
    if user_id.blank?
      raise ValidationError.new("user_id", "required", "User ID is required")
    end
    
    if amount <= 0
      raise ValidationError.new("amount", "invalid", "Amount must be positive")
    end
    
    if amount > 10_000
      raise ValidationError.new("amount", "limit_exceeded", "Amount exceeds maximum allowed")
    end
    
    # Simulate business logic check
    unless user_has_verified_account?(user_id)
      raise BusinessLogicError.new(
        "UNVERIFIED_ACCOUNT",
        "User account must be verified for orders over $100"
      ) if amount > 100
    end
    
    # Create order...
    Order.new(
      id: UUID.random.to_s,
      user_id: user_id,
      total: amount,
      status: "pending"
    )
  end

  # Demonstrates not found errors
  @[Micro::Method]
  def get_order(order_id : String) : Order
    order = find_order(order_id)
    
    unless order
      raise NotFoundError.new("Order", order_id)
    end
    
    order
  end

  # Demonstrates error recovery and fallbacks
  @[Micro::Method]
  def process_payment(order_id : String) : PaymentResult
    order = get_order(order_id)  # May raise NotFoundError
    
    begin
      # Try primary payment processor
      result = primary_processor.charge(order)
      PaymentResult.new(success: true, processor: "primary")
    rescue ex : PaymentProcessor::NetworkError
      Log.warn { "Primary processor failed: #{ex.message}" }
      
      # Fallback to secondary processor
      begin
        result = secondary_processor.charge(order)
        PaymentResult.new(success: true, processor: "secondary")
      rescue fallback_ex : PaymentProcessor::NetworkError
        # Both failed - return error but don't crash
        Log.error { "All payment processors failed" }
        PaymentResult.new(
          success: false, 
          error: "Payment processing temporarily unavailable"
        )
      end
    end
  end

  # Demonstrates using context for error enrichment
  @[Micro::Method]
  def cancel_order(order_id : String, reason : String) : Order
    order = get_order(order_id)
    
    # Add context for debugging
    context.set("order_status", order.status)
    context.set("cancellation_reason", reason)
    
    case order.status
    when "shipped"
      raise BusinessLogicError.new(
        "ORDER_SHIPPED",
        "Cannot cancel order that has already shipped"
      )
    when "delivered"
      raise BusinessLogicError.new(
        "ORDER_DELIVERED", 
        "Cannot cancel delivered order"
      )
    end
    
    # Proceed with cancellation...
    order
  end
end
```

The error handling demonstrates several best practices:

1. **Semantic error types**: Custom exceptions carry structured information about what went wrong, enabling better client handling.

2. **Validation separation**: Input validation happens early with clear error messages and field identification.

3. **Business logic errors**: Domain-specific errors use error codes that clients can programmatically handle.

4. **Graceful degradation**: Services can fall back to alternative implementations when primary systems fail.

5. **Context enrichment**: Adding debugging information to the context helps with troubleshooting production issues.

6. **Recovery middleware**: Prevents panics from crashing the entire service, maintaining availability even with unexpected errors.

The error handler middleware automatically:
- Maps `ValidationError` to HTTP 400 (Bad Request)
- Maps `NotFoundError` to HTTP 404 (Not Found)
- Maps `BusinessLogicError` to HTTP 409 (Conflict)
- Maps unknown errors to HTTP 500 (Internal Server Error)
- Includes error details in a consistent JSON format
- Preserves request IDs for correlation

## Next steps

These basic patterns form the foundation for building production services. The next sections cover:
- [Advanced patterns](advanced.md) for inter-service communication, pub/sub, and resilience
- [Demo walkthrough](demo-walkthrough.md) showing these patterns in a complete application

Key takeaways:
- Start simple and add complexity as needed
- Use type safety to catch errors at compile time
- Leverage middleware for cross-cutting concerns
- Design clear error hierarchies for better client handling
- Structure services around domain concepts