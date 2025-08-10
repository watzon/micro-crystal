# Broker

## Table of contents

- [Key concepts](#key-concepts)
- [Available brokers](#available-brokers)
- [Publishing events](#publishing-events)
- [Subscribing to events](#subscribing-to-events)
- [Event patterns](#event-patterns)
- [Message patterns](#message-patterns)
- [Performance tuning](#performance-tuning)
- [Best practices](#best-practices)
- [Related concepts](#related-concepts)

The broker provides asynchronous pub/sub messaging between services. It enables event-driven architectures where services can publish events and subscribe to topics without direct coupling.

## Key concepts

### Topics
Topics are named channels for messages. Publishers send messages to topics, and subscribers receive messages from topics they're interested in.

### Publishers and subscribers
Publishers emit events without knowing who will consume them. Subscribers express interest in topics and receive all messages published to those topics.

### Message delivery
Brokers can provide different delivery guarantees: at-most-once, at-least-once, or exactly-once delivery depending on the implementation.

## Available brokers

### Memory broker

For single-process and development use:

```crystal
broker = Micro::Brokers.memory

# All services in the same process share this broker
service_options = Micro::ServiceOptions.new(
  name: "api",
  version: "1.0.0",
  broker: broker,
  registry: registry
)
```

Memory broker characteristics:
- Zero network overhead
- Synchronous delivery
- No persistence
- Limited to single process

### NATS broker

For distributed production deployments:

```crystal
broker = Micro::Brokers.nats(ENV["NATS_URL"]? || "nats://127.0.0.1:4222")

service_options = Micro::ServiceOptions.new(
  name: "api",
  version: "1.0.0",
  broker: broker,
  registry: registry
)
```

NATS broker characteristics:
- Distributed messaging
- Simple pub/sub (core NATS)
- Optional JetStream features like persistence and replay depend on your NATS server setup; the stdlib broker uses core NATS APIs.

## Publishing events

### Direct publishing

Publish events directly through the broker:

```crystal
broker = Micro::Brokers.nats

# Create a message
message = Micro::Core::Broker::Message.new(
  body: {
    id: user.id,
    email: user.email,
    created_at: Time.utc
  }.to_json.to_slice,
  headers: HTTP::Headers{"Content-Type" => "application/json"}
)

# Publish the message
broker.publish("user.created", message)

# Publish with additional headers
message.headers["trace-id"] = ctx.request.id
message.headers["source"] = "order-service"
broker.publish("order.completed", message)
```

### Service event publishing

Services can publish events as part of their methods:

```crystal
@[Micro::Service(name: "users")]
class UserService
  include Micro::ServiceBase
  
  @[Micro::Method]
  def create_user(ctx : Micro::Core::Context, req : CreateUserRequest) : CreateUserResponse
    user = User.create!(
      name: req.name,
      email: req.email
    )
    
    # Publish event after successful creation  
    publish("user.created", UserCreatedEvent.new(
      user_id: user.id,
      email: user.email,
      timestamp: Time.utc
    ))
    
    CreateUserResponse.new(id: user.id)
  end
end
```

## Subscribing to events

### Service subscriptions

Use annotations to subscribe to topics:

```crystal
@[Micro::Service(name: "notifications")]
class NotificationService
  include Micro::ServiceBase
  
  @[Micro::Subscribe(topic: "user.created")]
  def handle_user_created(ctx : Micro::Core::Context, event : UserCreatedEvent)
    # Send welcome email
    send_email(event.email, "Welcome!")
  end
  
  @[Micro::Subscribe(topic: "order.*", queue_group: "email-workers")]
  def handle_order_events(ctx : Micro::Core::Context, event : JSON::Any)
    # Topic is available in the event metadata
    topic = ctx.request.headers["X-Topic"]?
    case topic
    when "order.created"
      send_order_confirmation(event)
    when "order.shipped"
      send_shipping_notification(event)
    end
  end
end
```

### Queue groups

Use queue groups for load balancing across subscribers:

```crystal
@[Micro::Subscribe(topic: "heavy.processing", queue_group: "workers")]
def process_heavy_task(ctx : Micro::Core::Context, task : Task)
  # Only one instance in the "workers" queue group
  # will receive each message
  perform_heavy_computation(task)
end
```

### Direct subscriptions

Subscribe directly through the broker:

```crystal
handler = ->(event : Micro::Core::Broker::Event) {
  metric_type = event.topic.split(".")[1]
  
  case metric_type
  when "cpu"
    record_cpu_metric(event.message.body)
  when "memory"
    record_memory_metric(event.message.body)
  end
}

subscriber = broker.subscribe("metrics.*", handler)

# Later: unsubscribe when done
subscriber.unsubscribe
```

## Event patterns

### Event sourcing

Use the broker for event sourcing:

```crystal
@[Micro::Service(name: "orders")]
class OrderService
  include Micro::ServiceBase
  
  @[Micro::Method]
  def create_order(ctx : Micro::Core::Context, req : CreateOrderRequest) : OrderResponse
    order = Order.new(req.items)
    
    # Publish domain events
    publish("order.events", OrderCreated.new(
      order_id: order.id,
      items: order.items,
      total: order.total,
      timestamp: Time.utc
    ))
    
    OrderResponse.new(id: order.id)
  end
  
  @[Micro::Method]
  def ship_order(ctx : Micro::Core::Context, req : ShipOrderRequest) : OrderResponse
    order = Order.find!(req.order_id)
    order.ship!
    
    # Publish state change event
    publish("order.events", OrderShipped.new(
      order_id: order.id,
      tracking_number: order.tracking_number,
      timestamp: Time.utc
    ))
    
    OrderResponse.new(id: order.id, status: "shipped")
  end
end
```

### Saga pattern

Coordinate distributed transactions:

```crystal
@[Micro::Service(name: "order-saga")]
class OrderSagaService
  include Micro::ServiceBase
  
  @[Micro::Subscribe(topic: "order.created")]
  def start_order_saga(ctx : Micro::Core::Context, event : OrderCreated)
    # Start the saga
    saga_id = UUID.random.to_s
    
    # Reserve inventory
    publish("inventory.reserve", ReserveInventory.new(
      saga_id: saga_id,
      order_id: event.order_id,
      items: event.items
    ))
  end
  
  @[Micro::Subscribe(topic: "inventory.reserved")]
  def handle_inventory_reserved(ctx : Micro::Core::Context, event : InventoryReserved)
    # Continue saga - charge payment
    publish("payment.charge", ChargePayment.new(
      saga_id: event.saga_id,
      order_id: event.order_id,
      amount: event.total
    ))
  end
  
  @[Micro::Subscribe(topic: "payment.failed")]
  def handle_payment_failed(ctx : Micro::Core::Context, event : PaymentFailed)
    # Compensate - release inventory
    publish("inventory.release", ReleaseInventory.new(
      saga_id: event.saga_id,
      order_id: event.order_id
    ))
    
    # Notify order service
    publish("order.failed", OrderFailed.new(
      order_id: event.order_id,
      reason: "Payment failed"
    ))
  end
end
```

### Event aggregation

Aggregate events for analytics:

```crystal
@[Micro::Service(name: "analytics")]
class AnalyticsService
  include Micro::ServiceBase
  
  @metrics = Hash(String, Int32).new(0)
  
  @[Micro::Subscribe(topic: "*.created")]
  def count_creations(ctx : Micro::Core::Context, event : JSON::Any)
    entity_type = ctx.topic.split(".")[0]
    @metrics[entity_type] += 1
    
    # Publish aggregated metrics periodically
    if @metrics.values.sum % 100 == 0
      publish("metrics.entities", @metrics)
    end
  end
end
```

## Message patterns

### Request-reply

Implement request-reply over pub/sub:

```crystal
# Service providing calculations
@[Micro::Subscribe(topic: "calc.requests")]
def handle_calc_request(ctx : Micro::Core::Context, req : CalcRequest)
  result = perform_calculation(req.expression)
  
  # Reply to the response topic
  publish(req.reply_to, CalcResponse.new(
    request_id: req.id,
    result: result
  ))
end

# Client requesting calculation
reply_topic = "calc.replies.#{UUID.random}"
handler = ->(event : Micro::Core::Broker::Event) {
  response = CalcResponse.from_json(String.new(event.message.body))
  puts "Result: #{response.result}"
}

subscription = broker.subscribe(reply_topic, handler)

message = Micro::Core::Broker::Message.new(
  CalcRequest.new(
    id: UUID.random.to_s,
    expression: "2 + 2",
    reply_to: reply_topic
  ).to_json.to_slice
)

broker.publish("calc.requests", message)
```

### Delayed messages

Schedule messages for future delivery:

```crystal
# With NATS JetStream
message = Micro::Core::Broker::Message.new(
  reminder_data.to_json.to_slice,
  headers: HTTP::Headers{
    "Nats-Msg-Delay" => "3600"  # Deliver in 1 hour
  }
)
broker.publish("reminders", message)
```

## Error handling

### Dead letter queues

Handle failed message processing:

```crystal
@[Micro::Subscribe(topic: "orders", queue_group: "processors")]
def process_order(ctx : Micro::Core::Context, order : Order)
  begin
    # Process order...
    validate_order(order)
    charge_payment(order)
  rescue ex
    # Send to dead letter queue
    publish("orders.dlq", {
      order: order,
      error: ex.message,
      timestamp: Time.utc
    })
    
    # Re-raise to signal failure
    raise ex
  end
end
```

### Retry logic

Implement exponential backoff:

```crystal
@[Micro::Subscribe(
  topic: "tasks",
  max_retries: 3,
  retry_backoff: 1
)]
def process_task(ctx : Micro::Core::Context, task : Task)
  # The annotation handles retry logic with exponential backoff
  perform_task(task)
end
```

## Performance tuning

### Batch processing

Process messages in batches:

```crystal
@batch = [] of Event
@batch_mutex = Mutex.new

@[Micro::Subscribe(topic: "events.stream")]
def collect_events(ctx : Micro::Core::Context, event : Event)
  @batch_mutex.synchronize do
    @batch << event
    
    if @batch.size >= 100
      process_batch(@batch)
      @batch.clear
    end
  end
end

# Also process on timer
spawn do
  loop do
    sleep 5.seconds
    @batch_mutex.synchronize do
      unless @batch.empty?
        process_batch(@batch)
        @batch.clear
      end
    end
  end
end
```

### Concurrent processing

Use fibers for concurrent message handling:

```crystal
@[Micro::Subscribe(
  topic: "jobs",
  queue_group: "workers"
)]
def process_job(ctx : Micro::Core::Context, job : Job)
  # Crystal handles concurrency via fibers automatically
  # Each request is processed in its own fiber
  perform_job(job)
end
```

## Best practices

### Use structured events
Define clear event types with schemas:

```crystal
struct UserCreatedEvent
  include JSON::Serializable
  include MessagePack::Serializable
  
  getter user_id : String
  getter email : String
  getter timestamp : Time
  getter version : String = "1.0"
end
```

### Design idempotent handlers
Ensure handlers can safely process duplicate messages:

```crystal
@[Micro::Subscribe(topic: "payments")]
def process_payment(ctx : Micro::Core::Context, payment : Payment)
  # Check if already processed
  return if Payment.exists?(payment.id)
  
  # Process payment idempotently
  Payment.create!(payment)
end
```

### Monitor message flow
Track metrics for observability:

```crystal
@[Micro::Subscribe(topic: "orders")]
def process_order(ctx : Micro::Core::Context, order : Order)
  start_time = Time.monotonic
  
  begin
    handle_order(order)
    
    publish("metrics.orders", {
      duration: (Time.monotonic - start_time).total_milliseconds,
      status: "success"
    })
  rescue ex
    publish("metrics.orders", {
      duration: (Time.monotonic - start_time).total_milliseconds,
      status: "error",
      error: ex.class.name
    })
    raise ex
  end
end
```

## Related concepts

- [Services](services.md) - How services publish and subscribe
- [Registry](registry.md) - Service discovery for event sources
- [Codecs](codecs.md) - Event serialization
- [Context](context.md) - Event context propagation