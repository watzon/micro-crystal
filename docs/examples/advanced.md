# Advanced service compositions

## Table of contents

- [Inter-service communication](#inter-service-communication)
- [Pub/sub patterns](#pubsub-patterns)
- [Circuit breakers](#circuit-breakers)
- [Request aggregation](#request-aggregation)
- [Next steps](#next-steps)

This guide explores complex µCrystal patterns for building robust, scalable microservice systems. These patterns address real-world challenges in distributed systems.

## Inter-service communication

Microservices need to communicate reliably. µCrystal provides a discovery-aware client that handles service resolution, load balancing, and failure scenarios.

```crystal
require "micro"

@[Micro::Service(name: "user-enrichment", version: "1.0.0")]
@[Micro::Middleware(["request_id", "logging", "timing", "error_handler"])]
class UserEnrichmentService
  include Micro::ServiceBase

  struct UserProfile
    include JSON::Serializable
    getter user_id : String
    getter name : String
    getter email : String
    getter preferences : Preferences?
    getter recent_orders : Array(OrderSummary)
    getter loyalty_status : LoyaltyStatus?
  end

  # Demonstrates service composition through multiple service calls
  @[Micro::Method]
  def get_enriched_profile(user_id : String) : UserProfile
    # Parallel service calls for better performance
    channel = Channel(Nil).new
    
    user_data = uninitialized UserData
    preferences = uninitialized Preferences?
    recent_orders = [] of OrderSummary
    loyalty_status = uninitialized LoyaltyStatus?
    errors = [] of String
    
    # Fetch core user data (required)
    spawn do
      begin
        response = client.call(
          service: "users",
          method: "/get_user",
          body: {id: user_id}.to_json.to_slice
        )
        
        if response.status == 200
          user_data = UserData.from_json(String.new(response.body))
        else
          errors << "Failed to fetch user data: HTTP #{response.status}"
        end
      rescue ex
        errors << "User service error: #{ex.message}"
      ensure
        channel.send(nil)
      end
    end
    
    # Fetch preferences (optional, with fallback)
    spawn do
      begin
        response = client.call(
          service: "preferences",
          method: "/get_preferences",
          body: {user_id: user_id}.to_json.to_slice,
          timeout: 2.seconds  # Shorter timeout for optional data
        )
        
        if response.status == 200
          preferences = Preferences.from_json(String.new(response.body))
        end
      rescue ex
        Log.warn { "Preferences service unavailable: #{ex.message}" }
        # Use default preferences as fallback
        preferences = Preferences.default_for_user(user_id)
      ensure
        channel.send(nil)
      end
    end
    
    # Fetch recent orders (optional, can fail)
    spawn do
      begin
        response = client.call(
          service: "orders",
          method: "/list_orders",
          body: {
            user_id: user_id,
            limit: 5,
            sort: "created_at_desc"
          }.to_json.to_slice
        )
        
        if response.status == 200
          orders_response = OrdersResponse.from_json(String.new(response.body))
          recent_orders = orders_response.orders.map do |order|
            OrderSummary.new(
              id: order.id,
              total: order.total,
              date: order.created_at
            )
          end
        end
      rescue ex
        Log.warn { "Orders service error: #{ex.message}" }
        # Continue without order history
      ensure
        channel.send(nil)
      end
    end
    
    # Fetch loyalty status (optional, cached)
    spawn do
      begin
        # Check cache first
        if cached_status = get_cached_loyalty_status(user_id)
          loyalty_status = cached_status
        else
          response = client.call(
            service: "loyalty",
            method: "/get_status",
            body: {user_id: user_id}.to_json.to_slice
          )
          
          if response.status == 200
            loyalty_status = LoyaltyStatus.from_json(String.new(response.body))
            # Cache for 1 hour
            cache_loyalty_status(user_id, loyalty_status, 1.hour)
          end
        end
      rescue ex
        Log.warn { "Loyalty service error: #{ex.message}" }
      ensure
        channel.send(nil)
      end
    end
    
    # Wait for all requests to complete
    4.times { channel.receive }
    
    # Check if we have the required data
    if errors.any?
      raise ServiceCompositionError.new(
        "Failed to fetch required user data: #{errors.join(", ")}"
      )
    end
    
    UserProfile.new(
      user_id: user_id,
      name: user_data.name,
      email: user_data.email,
      preferences: preferences,
      recent_orders: recent_orders,
      loyalty_status: loyalty_status
    )
  end

  # Demonstrates retry with circuit breaker pattern
  @[Micro::Method]
  def sync_user_to_crm(user_id : String) : SyncResult
    circuit_breaker = get_circuit_breaker("crm-sync")
    
    circuit_breaker.call do
      response = client.call(
        service: "crm-adapter",
        method: "/sync_user",
        body: {user_id: user_id}.to_json.to_slice,
        headers: HTTP::Headers{
          "X-Idempotency-Key" => "sync-#{user_id}-#{Time.utc.to_unix}"
        }
      )
      
      if response.status >= 500
        # Server errors should trip the circuit
        raise RemoteServiceError.new("CRM service error: #{response.status}")
      elsif response.status >= 400
        # Client errors shouldn't trip the circuit
        return SyncResult.new(success: false, error: "Invalid request")
      end
      
      SyncResult.from_json(String.new(response.body))
    end
  rescue Circuit::OpenError
    # Circuit is open, fail fast
    Log.error { "CRM sync circuit breaker is open" }
    SyncResult.new(success: false, error: "CRM service temporarily unavailable")
  end

  # Demonstrates request hedging for critical paths
  @[Micro::Method]
  def get_user_balance(user_id : String) : Balance
    # Send the same request to multiple instances
    # Return the first successful response
    hedge_request(
      service: "billing",
      method: "/get_balance",
      body: {user_id: user_id}.to_json.to_slice,
      instances: 2,
      delay: 50.milliseconds
    ) do |response|
      Balance.from_json(String.new(response.body))
    end
  end

  private def hedge_request(service : String, method : String, body : Bytes, 
                           instances : Int32, delay : Time::Span, &block)
    result_channel = Channel(Tuple(Int32, Core::TransportResponse)?).new
    error_channel = Channel(Exception).new
    
    instances.times do |i|
      spawn do
        begin
          # Add delay for subsequent requests
          sleep delay * i if i > 0
          
          response = client.call(
            service: service,
            method: method,
            body: body,
            # Use different selectors to hit different instances
            # Client call API does not accept a selector here; selection is handled inside discovery-aware clients
          )
          
          result_channel.send({i, response})
        rescue ex
          error_channel.send(ex)
        end
      end
    end
    
    # Return first successful response
    instances.times do
      select
      when result = result_channel.receive
        if result && result[1].status < 400
          # Cancel remaining requests (in a real implementation)
          return yield result[1]
        end
      when error = error_channel.receive
        # Continue waiting for other instances
      end
    end
    
    raise RemoteServiceError.new("All hedge requests failed")
  end
end
```

Key patterns demonstrated:

1. **Parallel composition**: Fetching data from multiple services concurrently reduces total latency. The enrichment service makes four parallel calls instead of sequential ones.

2. **Partial failure handling**: Optional data sources can fail without breaking the entire request. The service degrades gracefully by returning what it can.

3. **Response caching**: Frequently accessed, slowly changing data (like loyalty status) can be cached to reduce load on downstream services.

4. **Circuit breakers**: Protect against cascading failures by failing fast when a service is unhealthy. The circuit breaker monitors failure rates and temporarily blocks requests to struggling services.

5. **Request hedging**: For critical, read-only operations, sending the same request to multiple instances and using the first response improves tail latency.

## Pub/sub patterns

Event-driven architectures enable loose coupling between services. µCrystal's pub/sub support facilitates asynchronous communication patterns.

```crystal
require "micro"

@[Micro::Service(name: "order-processor", version: "1.0.0")]
@[Micro::Middleware(["request_id", "logging", "timing", "error_handler"])]
class OrderProcessorService
  include Micro::ServiceBase

  # Simple event handler
  @[Micro::Subscribe(topic: "orders.created")]
  def handle_order_created(event : OrderCreatedEvent)
    Log.info { "Processing new order: #{event.order_id}" }
    
    # Start order fulfillment workflow
    validate_inventory(event.items)
    reserve_inventory(event.items)
    initiate_payment(event.order_id, event.total)
    
    # Publish next event in the workflow
    publish("orders.validated", OrderValidatedEvent.new(
      order_id: event.order_id,
      validated_at: Time.utc
    ))
  end

  # Queue group ensures only one instance processes each event
  @[Micro::Subscribe(
    topic: "payments.completed",
    queue_group: "order-processor"
  )]
  def handle_payment_completed(event : PaymentCompletedEvent)
    Log.info { "Payment completed for order: #{event.order_id}" }
    
    # Update order status
    update_order_status(event.order_id, "paid")
    
    # Trigger shipping workflow
    publish("orders.ready_to_ship", OrderReadyToShipEvent.new(
      order_id: event.order_id,
      payment_id: event.payment_id
    ))
  end

  # Retry configuration for handling transient failures
  @[Micro::Subscribe(
    topic: "inventory.updated",
    queue_group: "order-processor",
    max_retries: 5,
    retry_backoff: 10  # seconds
  )]
  def handle_inventory_update(event : InventoryUpdateEvent)
    # This handler might fail due to database issues
    # The retry mechanism will automatically retry with exponential backoff
    
    affected_orders = find_orders_waiting_for_item(event.item_id)
    
    affected_orders.each do |order|
      if can_fulfill_order?(order)
        Log.info { "Order #{order.id} can now be fulfilled" }
        publish("orders.fulfillable", OrderFulfillableEvent.new(
          order_id: order.id,
          item_id: event.item_id
        ))
      end
    end
  end

  # Demonstrates event sourcing pattern
  @[Micro::Subscribe(topic: "orders.*")]
  def handle_all_order_events(event : JSON::Any)
    # Store all events for audit and replay capability
    store_event(
      aggregate_id: event["order_id"].as_s,
      event_type: context.get("event_topic", String),
      event_data: event,
      occurred_at: Time.utc
    )
  end

  # Demonstrates saga pattern for distributed transactions
  @[Micro::Method]
  def process_order_saga(order : Order) : SagaResult
    saga = OrderSaga.new(order.id)
    
    begin
      # Step 1: Reserve inventory
      saga.add_step("reserve_inventory") do
        result = client.call("inventory", "/reserve", {
          items: order.items.map(&.to_h)
        }.to_json.to_slice)
        
        if result.status != 200
          raise SagaError.new("Failed to reserve inventory")
        end
        
        ReservationResult.from_json(String.new(result.body))
      end
      
      # Compensation for step 1
      saga.add_compensation("reserve_inventory") do |reservation_result|
        client.call("inventory", "/release", {
          reservation_id: reservation_result.id
        }.to_json.to_slice)
      end
      
      # Step 2: Process payment
      saga.add_step("process_payment") do
        result = client.call("payments", "/charge", {
          order_id: order.id,
          amount: order.total,
          customer_id: order.customer_id
        }.to_json.to_slice)
        
        if result.status != 200
          raise SagaError.new("Payment failed")
        end
        
        PaymentResult.from_json(String.new(result.body))
      end
      
      # Compensation for step 2
      saga.add_compensation("process_payment") do |payment_result|
        client.call("payments", "/refund", {
          payment_id: payment_result.id
        }.to_json.to_slice)
      end
      
      # Step 3: Create shipment
      saga.add_step("create_shipment") do
        result = client.call("shipping", "/create", {
          order_id: order.id,
          address: order.shipping_address
        }.to_json.to_slice)
        
        if result.status != 200
          raise SagaError.new("Failed to create shipment")
        end
        
        ShipmentResult.from_json(String.new(result.body))
      end
      
      # Execute saga
      saga_result = saga.execute
      
      # Publish success event
      publish("orders.processed", OrderProcessedEvent.new(
        order_id: order.id,
        reservation_id: saga_result.results["reserve_inventory"].id,
        payment_id: saga_result.results["process_payment"].id,
        shipment_id: saga_result.results["create_shipment"].id
      ))
      
      saga_result
    rescue ex : SagaError
      # Saga will automatically run compensations
      Log.error { "Saga failed: #{ex.message}" }
      
      # Publish failure event
      publish("orders.failed", OrderFailedEvent.new(
        order_id: order.id,
        reason: ex.message,
        failed_at: Time.utc
      ))
      
      raise ex
    end
  end

  # Demonstrates event aggregation and windowing
  @[Micro::Subscribe(topic: "metrics.order_placed")]
  def aggregate_order_metrics(event : OrderMetricEvent)
    # Aggregate metrics in time windows
    window = TimeWindow.current(5.minutes)
    
    window.increment("order_count")
    window.add("order_value", event.total)
    window.add_to_set("unique_customers", event.customer_id)
    
    # Publish aggregated metrics when window closes
    if window.closing_soon?
      publish("metrics.orders.aggregated", {
        window_start: window.start_time,
        window_end: window.end_time,
        total_orders: window.get("order_count"),
        total_value: window.get("order_value"),
        unique_customers: window.set_size("unique_customers"),
        average_order_value: window.average("order_value")
      })
    end
  end
end

# Supporting classes for saga pattern
class OrderSaga
  alias StepResult = JSON::Any
  
  struct Step
    getter name : String
    getter action : Proc(StepResult)
    getter compensation : Proc(StepResult, Nil)?
    
    def initialize(@name, @action, @compensation = nil)
    end
  end
  
  def initialize(@saga_id : String)
    @steps = [] of Step
    @completed_steps = [] of String
    @results = {} of String => StepResult
  end
  
  def add_step(name : String, &block : -> StepResult)
    @steps << Step.new(name, block)
  end
  
  def add_compensation(step_name : String, &block : StepResult ->)
    step = @steps.find { |s| s.name == step_name }
    raise "Step #{step_name} not found" unless step
    
    step.compensation = block
  end
  
  def execute : SagaResult
    @steps.each do |step|
      begin
        Log.info { "Executing saga step: #{step.name}" }
        result = step.action.call
        @results[step.name] = result
        @completed_steps << step.name
      rescue ex
        Log.error { "Saga step #{step.name} failed: #{ex.message}" }
        compensate
        raise SagaError.new("Saga failed at step #{step.name}: #{ex.message}")
      end
    end
    
    SagaResult.new(success: true, results: @results)
  end
  
  private def compensate
    Log.info { "Running saga compensations" }
    
    @completed_steps.reverse.each do |step_name|
      step = @steps.find { |s| s.name == step_name }
      next unless step && step.compensation
      
      begin
        Log.info { "Compensating step: #{step_name}" }
        result = @results[step_name]
        step.compensation.not_nil!.call(result)
      rescue ex
        Log.error { "Compensation failed for #{step_name}: #{ex.message}" }
        # Continue with other compensations
      end
    end
  end
end
```

Event-driven patterns shown:

1. **Simple event handlers**: The `@[Micro::Subscribe]` annotation automatically subscribes to topics and deserializes events to the expected type.

2. **Queue groups**: Ensure that only one instance in a group processes each event, enabling horizontal scaling while preventing duplicate processing.

3. **Retry mechanisms**: Built-in retry support with configurable backoff helps handle transient failures in event processing.

4. **Event sourcing**: Capturing all events enables audit trails, debugging, and the ability to replay events to rebuild state.

5. **Saga pattern**: Manages distributed transactions across multiple services with automatic compensation on failure. Each step has a corresponding compensation action that runs if later steps fail.

6. **Event aggregation**: Time-windowed aggregation of events enables real-time analytics and monitoring without overwhelming downstream systems.

## Circuit breakers

Circuit breakers prevent cascading failures in distributed systems. When a service is struggling, the circuit breaker "opens" to fail fast rather than waiting for timeouts.

```crystal
require "micro"

# Circuit breaker implementation
class CircuitBreaker
  enum State
    Closed
    Open
    HalfOpen
  end
  
  def initialize(@name : String,
                 @failure_threshold : Int32 = 5,
                 @success_threshold : Int32 = 2,
                 @timeout : Time::Span = 60.seconds,
                 @half_open_requests : Int32 = 3)
    @state = State::Closed
    @failure_count = 0
    @success_count = 0
    @last_failure_time = Time.utc
    @mutex = Mutex.new
  end
  
  def call(&block)
    @mutex.synchronize do
      case @state
      when State::Open
        if Time.utc - @last_failure_time > @timeout
          @state = State::HalfOpen
          @success_count = 0
          Log.info { "Circuit #{@name} entering half-open state" }
        else
          raise Circuit::OpenError.new("Circuit #{@name} is open")
        end
      end
    end
    
    begin
      result = yield
      on_success
      result
    rescue ex
      on_failure
      raise ex
    end
  end
  
  private def on_success
    @mutex.synchronize do
      case @state
      when State::HalfOpen
        @success_count += 1
        if @success_count >= @success_threshold
          @state = State::Closed
          @failure_count = 0
          Log.info { "Circuit #{@name} closed after recovery" }
        end
      when State::Closed
        @failure_count = 0
      end
    end
  end
  
  private def on_failure
    @mutex.synchronize do
      @failure_count += 1
      @last_failure_time = Time.utc
      
      case @state
      when State::Closed
        if @failure_count >= @failure_threshold
          @state = State::Open
          Log.warn { "Circuit #{@name} opened after #{@failure_count} failures" }
        end
      when State::HalfOpen
        @state = State::Open
        Log.warn { "Circuit #{@name} reopened due to failure in half-open state" }
      end
    end
  end
end

@[Micro::Service(name: "resilient-gateway", version: "1.0.0")]
class ResilientGatewayService
  include Micro::ServiceBase
  
  # Circuit breakers for each downstream service
  @@circuit_breakers = {} of String => CircuitBreaker
  
  def self.circuit_breaker(service_name : String) : CircuitBreaker
    @@circuit_breakers[service_name] ||= CircuitBreaker.new(
      name: service_name,
      failure_threshold: 5,
      success_threshold: 2,
      timeout: 30.seconds
    )
  end
  
  # Demonstrates circuit breaker with fallback
  @[Micro::Method]
  def get_product_details(product_id : String) : ProductDetails
    # Try primary service with circuit breaker
    begin
      circuit = self.class.circuit_breaker("catalog-service")
      
      circuit.call do
        response = client.call(
          service: "catalog",
          method: "/get_product",
          body: {id: product_id}.to_json.to_slice,
          timeout: 3.seconds
        )
        
        if response.status >= 500
          raise RemoteServiceError.new("Catalog service error")
        end
        
        ProductDetails.from_json(String.new(response.body))
      end
    rescue Circuit::OpenError
      # Circuit is open, try fallback
      Log.warn { "Catalog circuit open, using cache" }
      
      # Try cache
      if cached = get_cached_product(product_id)
        return cached
      end
      
      # Try read replica
      begin
        response = client.call(
          service: "catalog-replica",
          method: "/get_product",
          body: {id: product_id}.to_json.to_slice
        )
        
        ProductDetails.from_json(String.new(response.body))
      rescue ex
        # All options exhausted
        raise ServiceUnavailableError.new(
          "Unable to fetch product details: primary circuit open, no cache, replica failed"
        )
      end
    end
  end
  
  # Demonstrates adaptive circuit breaker based on response times
  @[Micro::Method]
  def search_products(query : String) : SearchResults
    circuit = AdaptiveCircuitBreaker.new(
      name: "search-service",
      latency_threshold: 1.second,
      percentile: 95  # Open if 95th percentile exceeds threshold
    )
    
    circuit.call do
      start = Time.monotonic
      
      response = client.call(
        service: "search",
        method: "/search",
        body: {q: query}.to_json.to_slice
      )
      
      # Record latency for adaptive thresholds
      circuit.record_latency(Time.monotonic - start)
      
      SearchResults.from_json(String.new(response.body))
    end
  rescue Circuit::OpenError
    # Return degraded results
    SearchResults.new(
      products: [] of Product,
      total: 0,
      degraded: true,
      message: "Search is temporarily unavailable"
    )
  end
end
```

Circuit breaker benefits:

1. **Fail fast**: When a service is down, fail immediately rather than waiting for timeouts.

2. **Automatic recovery**: The half-open state allows the circuit to test if the service has recovered.

3. **Prevent cascading failures**: By failing fast, we prevent backed-up requests from overwhelming the system.

4. **Graceful degradation**: When circuits open, services can fall back to caches, replicas, or degraded functionality.

5. **Adaptive thresholds**: Advanced circuit breakers can adapt based on response times and error rates rather than simple counts.

## Request aggregation

API gateways often need to aggregate data from multiple services into a single response. This pattern reduces client-side complexity and network overhead.

```crystal
require "micro"

@[Micro::Service(name: "api-aggregator", version: "1.0.0")]
class APIAggregatorService
  include Micro::ServiceBase
  
  # GraphQL-style field selection
  struct FieldSelector
    getter fields : Set(String)
    getter nested : Hash(String, FieldSelector)
    
    def self.parse(fields_param : String) : FieldSelector
      # Parse "id,name,orders(id,total),preferences" format
      # Implementation details omitted for brevity
    end
  end
  
  # Aggregate user data based on requested fields
  @[Micro::Method]
  def get_user_aggregate(user_id : String, fields : String) : JSON::Any
    selector = FieldSelector.parse(fields)
    result = {} of String => JSON::Any
    
    # Always fetch core user data
    if selector.fields.includes_any?("id", "name", "email")
      user_data = fetch_user_core(user_id)
      result["id"] = JSON::Any.new(user_data.id) if selector.fields.includes?("id")
      result["name"] = JSON::Any.new(user_data.name) if selector.fields.includes?("name")
      result["email"] = JSON::Any.new(user_data.email) if selector.fields.includes?("email")
    end
    
    # Parallel fetch for optional data
    futures = [] of Fiber
    
    # Orders
    if selector.fields.includes?("orders")
      futures << spawn do
        orders = fetch_user_orders(user_id)
        order_selector = selector.nested["orders"]?
        
        if order_selector
          # Filter order fields based on selector
          filtered_orders = orders.map do |order|
            filter_fields(order, order_selector)
          end
          result["orders"] = JSON::Any.new(filtered_orders)
        else
          result["orders"] = JSON::Any.new(orders)
        end
      end
    end
    
    # Preferences
    if selector.fields.includes?("preferences")
      futures << spawn do
        begin
          prefs = fetch_user_preferences(user_id)
          result["preferences"] = JSON::Any.new(prefs)
        rescue ex
          # Optional field, include null on failure
          result["preferences"] = JSON::Any.new(nil)
        end
      end
    end
    
    # Analytics
    if selector.fields.includes?("analytics")
      futures << spawn do
        analytics = fetch_user_analytics(user_id)
        result["analytics"] = JSON::Any.new(analytics)
      end
    end
    
    # Wait for all parallel fetches
    futures.each(&.wait)
    
    JSON::Any.new(result)
  end
  
  # Batch aggregation for multiple entities
  @[Micro::Method]
  def get_products_with_inventory(product_ids : Array(String)) : Array(ProductWithInventory)
    # Batch fetch products
    products_response = client.call(
      service: "catalog",
      method: "/batch_get_products",
      body: {ids: product_ids}.to_json.to_slice
    )
    
    products = Array(Product).from_json(String.new(products_response.body))
    
    # Batch fetch inventory
    inventory_response = client.call(
      service: "inventory",
      method: "/batch_get_inventory",
      body: {product_ids: product_ids}.to_json.to_slice
    )
    
    inventory_map = Hash(String, Inventory).from_json(String.new(inventory_response.body))
    
    # Combine results
    products.map do |product|
      ProductWithInventory.new(
        product: product,
        inventory: inventory_map[product.id]? || Inventory.new(
          product_id: product.id,
          quantity: 0,
          status: "out_of_stock"
        )
      )
    end
  end
  
  # Smart aggregation with caching and batch optimization
  @[Micro::Method]
  def get_dashboard_data(user_id : String) : DashboardData
    # Check if full dashboard is cached
    cache_key = "dashboard:#{user_id}"
    if cached = get_cached(cache_key, DashboardData)
      return cached if cached.fresh?(5.minutes)
    end
    
    # Parallel data fetching with different cache strategies
    user_future = spawn { fetch_with_cache("user:#{user_id}", 1.hour) { fetch_user(user_id) } }
    
    stats_future = spawn { 
      fetch_with_cache("user_stats:#{user_id}", 5.minutes) { 
        fetch_user_statistics(user_id) 
      } 
    }
    
    notifications_future = spawn {
      # Don't cache notifications - always fresh
      fetch_notifications(user_id, unread_only: true)
    }
    
    recommendations_future = spawn {
      fetch_with_cache("recommendations:#{user_id}", 30.minutes) {
        fetch_personalized_recommendations(user_id, limit: 5)
      }
    }
    
    # Collect results
    dashboard = DashboardData.new(
      user: user_future.wait,
      statistics: stats_future.wait,
      notifications: notifications_future.wait,
      recommendations: recommendations_future.wait
    )
    
    # Cache complete dashboard
    cache_set(cache_key, dashboard, 5.minutes)
    
    dashboard
  end
  
  # Helper for field filtering
  private def filter_fields(object : T, selector : FieldSelector) : Hash(String, JSON::Any) forall T
    result = {} of String => JSON::Any
    
    object.to_h.each do |key, value|
      if selector.fields.includes?(key.to_s)
        result[key.to_s] = JSON::Any.new(value)
      end
    end
    
    result
  end
  
  # Helper for caching with fetch block
  private def fetch_with_cache(key : String, ttl : Time::Span, &block : -> T) : T forall T
    if cached = get_cached(key, T)
      return cached
    end
    
    value = yield
    cache_set(key, value, ttl)
    value
  end
end
```

Aggregation patterns demonstrated:

1. **Field selection**: Clients can request only the fields they need, reducing bandwidth and processing.

2. **Parallel fetching**: Multiple service calls execute concurrently to minimize total latency.

3. **Partial failure tolerance**: Optional fields can fail without breaking the entire response.

4. **Batch operations**: Fetching multiple entities in a single call is more efficient than N+1 queries.

5. **Smart caching**: Different data types have different cache strategies based on volatility.

6. **Response shaping**: The aggregator shapes responses to match client needs, hiding service boundaries.

## Next steps

These advanced patterns enable building resilient, scalable microservice systems. Key concepts to remember:

- **Design for failure**: Assume services will fail and build in resilience
- **Embrace asynchrony**: Event-driven patterns enable loose coupling
- **Cache strategically**: Different data has different freshness requirements
- **Monitor everything**: Circuit breakers and health checks need metrics
- **Fail gracefully**: Degraded service is better than no service

See the [demo walkthrough](demo-walkthrough.md) for these patterns in action within a complete application.