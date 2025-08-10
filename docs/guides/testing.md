# Testing Guide

This guide covers testing strategies for µCrystal services, including the service harness, integration testing, gateway test client, and best practices.

## Table of Contents

- [Testing Overview](#testing-overview)
- [Unit Testing Services](#unit-testing-services)
- [Service Harness](#service-harness)
- [Integration Testing](#integration-testing)
- [Gateway Testing](#gateway-testing)
- [Mocking and Stubbing](#mocking-and-stubbing)
- [Performance Testing](#performance-testing)
- [Contract Testing](#contract-testing)
- [Best Practices](#best-practices)

## Testing Overview

µCrystal provides several testing utilities:

- **Service Harness**: In-process service testing without network overhead
- **Loopback Transport**: Zero-network transport for fast tests
- **Gateway Test Client**: Test gateway configurations
- **Mock Registry**: Simulate service discovery
- **Test Helpers**: Common testing utilities

## Unit Testing Services

### Basic Service Test

```crystal
require "spec"
require "micro/stdlib/testing"

describe CatalogService do
  it "returns product list" do
    # Create service harness
    harness = Micro::Stdlib::Testing::ServiceHarness.build(
      name: "catalog",
      version: "1.0.0"
    ) do
      # Register the actual service handlers
      handle "/list_products" do |context|
        context.response.body = [
          {id: "1", name: "Product 1", price: 9.99},
          {id: "2", name: "Product 2", price: 19.99}
        ]
      end
    end
    
    # Make request
    response = harness.call_json("list_products")
    
    # Verify response
    response.status.should eq(200)
    products = Array(Hash(String, JSON::Any)).from_json(response.body)
    products.size.should eq(2)
    products[0]["name"].should eq("Product 1")
  ensure
    harness.try(&.stop)
  end
end
```

### Testing with Real Service Classes

```crystal
describe OrderService do
  getter harness : Micro::Stdlib::Testing::ServiceHarness
  
  def initialize
    @harness = create_harness
  end
  
  private def create_harness
    # Create harness that runs the actual service
    harness = Micro::Stdlib::Testing::ServiceHarness.new(
      name: "orders",
      version: "1.0.0"
    )
    
    # Create service instance and register handlers
    service = OrderService.new
    service.register_handlers(harness.service)
    
    harness.start
    harness
  end
  
  it "creates an order" do
    input = {
      customer_id: "cust-123",
      items: [
        {product_id: "prod-1", quantity: 2},
        {product_id: "prod-2", quantity: 1}
      ]
    }
    
    response = harness.call_json("create_order", input)
    
    response.status.should eq(200)
    order = Order.from_json(response.body)
    order.customer_id.should eq("cust-123")
    order.items.size.should eq(2)
  end
  
  it "handles invalid input" do
    response = harness.call_json("create_order", {})
    
    response.status.should eq(400)
    error = JSON.parse(response.body)
    error["error"].as_s.should contain("customer_id required")
  end
  
  after_each do
    # Clean up test data if needed
    OrderService.clear_test_data
  end
  
  after_all do
    harness.stop
  end
end
```

## Service Harness

### Harness Features

The service harness provides:
- In-process service execution
- No network overhead
- Full middleware support
- Request/response access
- Easy setup and teardown

### Advanced Harness Usage

```crystal
describe "Service with dependencies" do
  getter catalog_harness : Micro::Stdlib::Testing::ServiceHarness
  getter order_harness : Micro::Stdlib::Testing::ServiceHarness
  
  before_all do
    # Set up catalog service
    @catalog_harness = Micro::Stdlib::Testing::ServiceHarness.build(
      name: "catalog",
      version: "1.0.0"
    ) do
      handle "/get_product" do |context|
        product_id = String.from_json(context.request.body)
        
        products = {
          "prod-1" => {id: "prod-1", name: "Widget", price: 9.99},
          "prod-2" => {id: "prod-2", name: "Gadget", price: 19.99}
        }
        
        if product = products[product_id]?
          context.response.body = product
        else
          context.response.status = 404
          context.response.body = {error: "Product not found"}
        end
      end
    end
    
    # Set up order service with catalog dependency
    @order_harness = Micro::Stdlib::Testing::ServiceHarness.new(
      name: "orders",
      version: "1.0.0"
    )
    
    # Configure order service to use catalog harness
    order_service = OrderService.new
    order_service.client = catalog_harness.client
    order_service.register_handlers(@order_harness.service)
    
    @order_harness.start
  end
  
  it "creates order with product lookup" do
    order_input = {
      customer_id: "cust-123",
      items: [{product_id: "prod-1", quantity: 2}]
    }
    
    response = order_harness.call_json("create_order", order_input)
    
    response.status.should eq(200)
    order = JSON.parse(response.body)
    order["total"].as_f.should eq(19.98)  # 9.99 * 2
  end
  
  after_all do
    catalog_harness.stop
    order_harness.stop
  end
end
```

### Testing Middleware

```crystal
describe "Middleware behavior" do
  it "applies rate limiting" do
    harness = Micro::Stdlib::Testing::ServiceHarness.build(
      name: "api",
      version: "1.0.0"
    ) do
      # Add rate limit middleware
      service.use(Micro::Stdlib::Middleware::RateLimitMiddleware.new(
        requests: 2,
        per: 1.second
      ))
      
      handle "/endpoint" do |context|
        context.response.body = {message: "success"}
      end
    end
    
    # First two requests succeed
    2.times do
      response = harness.call_json("endpoint")
      response.status.should eq(200)
    end
    
    # Third request rate limited
    response = harness.call_json("endpoint")
    response.status.should eq(429)
    
    # Wait and retry
    sleep 1.second
    response = harness.call_json("endpoint")
    response.status.should eq(200)
  ensure
    harness.try(&.stop)
  end
end
```

## Integration Testing

### Multi-Service Testing

```crystal
class IntegrationTest < Micro::TestCase
  def setup_services
    # Start all services with test configurations
    @catalog = start_service(CatalogService, port: 8001)
    @orders = start_service(OrderService, port: 8002)
    @users = start_service(UserService, port: 8003)
    
    # Wait for services to be ready
    wait_for_ready([@catalog, @orders, @users])
  end
  
  def test_end_to_end_order_flow
    # Create user
    user_response = @users.client.call_json("create_user", {
      email: "test@example.com",
      name: "Test User"
    })
    user = User.from_json(user_response.body)
    
    # Browse catalog
    catalog_response = @catalog.client.call_json("list_products")
    products = Array(Product).from_json(catalog_response.body)
    
    # Create order
    order_response = @orders.client.call_json("create_order", {
      user_id: user.id,
      items: [
        {product_id: products[0].id, quantity: 1}
      ]
    })
    order = Order.from_json(order_response.body)
    
    # Verify order
    order.user_id.should eq(user.id)
    order.status.should eq("pending")
    order.total.should be > 0
  end
  
  def teardown
    [@catalog, @orders, @users].each(&.stop)
  end
end
```

### Database Testing

```crystal
describe "Service with database" do
  # Use transactions for test isolation
  around_each do |example|
    DB.transaction do
      example.run
      raise DB::Rollback.new  # Rollback after test
    end
  end
  
  it "persists data correctly" do
    harness = create_service_harness
    
    # Create record
    response = harness.call_json("create_product", {
      name: "Test Product",
      price: 29.99
    })
    
    product = Product.from_json(response.body)
    
    # Verify in database
    db_product = DB.query_one(
      "SELECT * FROM products WHERE id = ?",
      product.id,
      as: Product
    )
    
    db_product.name.should eq("Test Product")
    db_product.price.should eq(29.99)
  end
end
```

### Message Queue Testing

```crystal
describe "Event publishing" do
  getter harness : Micro::Stdlib::Testing::ServiceHarness
  getter messages : Array(Message)
  
  before_each do
    @messages = [] of Message
    
    # Use test broker that captures messages
    test_broker = TestBroker.new do |topic, message|
      @messages << Message.new(topic, message)
    end
    
    @harness = Micro::Stdlib::Testing::ServiceHarness.new(
      name: "events",
      version: "1.0.0",
      broker: test_broker
    )
    
    # Set up service
    service = EventService.new
    service.register_handlers(harness.service)
    harness.start
  end
  
  it "publishes order created event" do
    response = harness.call_json("create_order", {
      customer_id: "cust-123",
      total: 99.99
    })
    
    response.status.should eq(200)
    
    # Verify event published
    messages.size.should eq(1)
    
    event = messages[0]
    event.topic.should eq("orders.created")
    
    payload = JSON.parse(event.message)
    payload["customer_id"].should eq("cust-123")
    payload["total"].should eq(99.99)
  end
end
```

## Gateway Testing

### Testing Gateway Routes

```crystal
describe "API Gateway" do
  getter gateway : Micro::Stdlib::Testing::GatewayTestClient
  getter catalog_service : Micro::Stdlib::Testing::ServiceHarness
  
  before_all do
    # Start backend service
    @catalog_service = Micro::Stdlib::Testing::ServiceHarness.build(
      name: "catalog",
      version: "1.0.0"
    ) do
      handle "/list_products" do |context|
        context.response.body = [
          {id: "1", name: "Product 1"},
          {id: "2", name: "Product 2"}
        ]
      end
    end
    
    # Create test gateway using the builder DSL
    @gateway = Micro::Stdlib::Testing.build_gateway do
      service "catalog" do
        route "GET", "/products", to: "list_products"
        route "GET", "/products/:id", to: "get_product"
      end
    end
  end
  
  it "routes to catalog service" do
    status, headers, body = @gateway.request("GET", "/products")
    
    status.should eq(200)
    products = JSON.parse(body)
    products.as_a.size.should eq(2)
  end
  
  it "handles JSON requests" do
    status, headers, json = @gateway.request_json("GET", "/products")
    
    status.should eq(200)
    json.as_a.size.should eq(2)
    json.as_a[0]["name"].as_s.should eq("Product 1")
  end
end
```

### Testing Gateway Middleware

```crystal
describe "Gateway middleware" do
  it "applies authentication" do
    gateway = TestGateway.new do
      # Add auth middleware
      use_middleware([
        "jwt_auth"
      ])
      
      route "/api/secure", to: "secure-service"
    end
    
    # Request without token
    response = gateway.get("/api/secure")
    response.status.should eq(401)
    
    # Request with valid token
    token = generate_test_jwt(user_id: "123")
    response = gateway.get("/api/secure", headers: {
      "Authorization" => "Bearer #{token}"
    })
    response.status.should eq(200)
  end
  
  it "rate limits requests" do
    gateway = TestGateway.new do
      route "/api/limited" do
        rate_limit(requests: 2, per: 1.second)
        to "service"
      end
    end
    
    # Exhaust rate limit
    2.times do
      response = gateway.get("/api/limited")
      response.status.should eq(200)
    end
    
    # Should be rate limited
    response = gateway.get("/api/limited")
    response.status.should eq(429)
    response.headers["X-RateLimit-Remaining"]?.should eq("0")
  end
end
```

## Mocking and Stubbing

### Service Mocks

```crystal
class MockCatalogService < Micro::Stdlib::Testing::MockService
  def initialize
    super("catalog", "1.0.0")
    
    # Define mock responses
    stub_method("list_products") do |context|
      [
        {id: "mock-1", name: "Mock Product 1", price: 10.00},
        {id: "mock-2", name: "Mock Product 2", price: 20.00}
      ]
    end
    
    stub_method("get_product") do |context|
      id = String.from_json(context.request.body)
      
      if id == "mock-1"
        {id: "mock-1", name: "Mock Product 1", price: 10.00}
      else
        raise Micro::Core::NotFoundError.new("Product not found")
      end
    end
  end
end

describe "Order service with mocked catalog" do
  it "calculates order total" do
    # Use mock catalog
    catalog_mock = MockCatalogService.new
    
    # Configure order service
    order_harness = Micro::Stdlib::Testing::ServiceHarness.new(
      name: "orders",
      version: "1.0.0"
    )
    
    order_service = OrderService.new
    order_service.catalog_client = catalog_mock.client
    order_service.register_handlers(order_harness.service)
    
    order_harness.start
    
    # Test order creation
    response = order_harness.call_json("create_order", {
      items: [
        {product_id: "mock-1", quantity: 2},
        {product_id: "mock-2", quantity: 1}
      ]
    })
    
    order = Order.from_json(response.body)
    order.total.should eq(40.00)  # (10 * 2) + (20 * 1)
  end
end
```

### HTTP Mocking

```crystal
require "webmock"

describe "External API integration" do
  it "handles payment processing" do
    # Mock external payment API
    WebMock.stub(:post, "https://payment.api/charge")
      .with(body: {amount: 99.99, currency: "USD"})
      .to_return(status: 200, body: {
        transaction_id: "txn_123",
        status: "success"
      }.to_json)
    
    harness = create_payment_service_harness
    
    response = harness.call_json("process_payment", {
      amount: 99.99,
      currency: "USD"
    })
    
    response.status.should eq(200)
    result = JSON.parse(response.body)
    result["transaction_id"].should eq("txn_123")
  end
  
  it "handles payment failures" do
    WebMock.stub(:post, "https://payment.api/charge")
      .to_return(status: 402, body: {
        error: "Insufficient funds"
      }.to_json)
    
    harness = create_payment_service_harness
    
    response = harness.call_json("process_payment", {
      amount: 99.99,
      currency: "USD"
    })
    
    response.status.should eq(402)
    error = JSON.parse(response.body)
    error["error"].should contain("Insufficient funds")
  end
end
```

## Performance Testing

### Load Testing

```crystal
describe "Performance" do
  it "handles concurrent requests" do
    harness = create_service_harness
    
    # Warm up
    10.times do
      harness.call_json("list_products")
    end
    
    # Measure performance
    start_time = Time.monotonic
    responses = Channel(HTTP::Status).new
    
    # Concurrent requests
    100.times do
      spawn do
        response = harness.call_json("list_products")
        responses.send(response.status)
      end
    end
    
    # Collect results
    statuses = Array(HTTP::Status).new
    100.times do
      statuses << responses.receive
    end
    
    duration = Time.monotonic - start_time
    
    # Verify results
    statuses.all?(&.success?).should be_true
    duration.should be < 1.second  # 100 requests in under 1 second
    
    # Calculate throughput
    throughput = 100 / duration.total_seconds
    puts "Throughput: #{throughput.round(2)} req/s"
  end
end
```

### Benchmark Testing

```crystal
require "benchmark"

describe "Service benchmarks" do
  getter harness : Micro::Stdlib::Testing::ServiceHarness
  
  before_all do
    @harness = create_service_harness_with_data
  end
  
  it "benchmarks different operations" do
    Benchmark.ips do |x|
      x.report("list_products") do
        harness.call_json("list_products")
      end
      
      x.report("get_product") do
        harness.call_json("get_product", "prod-1")
      end
      
      x.report("search_products") do
        harness.call_json("search_products", {query: "widget"})
      end
      
      x.compare!
    end
  end
  
  it "measures memory usage" do
    initial_memory = GC.stats.heap_size
    
    1000.times do
      response = harness.call_json("list_products")
      # Force response to be consumed
      JSON.parse(response.body)
    end
    
    GC.collect
    final_memory = GC.stats.heap_size
    
    memory_growth = final_memory - initial_memory
    memory_growth.should be < 10.megabytes
  end
end
```

## Contract Testing

### Consumer Contract Tests

```crystal
# Define service contract
abstract class CatalogContract
  abstract def list_products : Array(Product)
  abstract def get_product(id : String) : Product?
  abstract def search_products(query : String, limit : Int32 = 10) : Array(Product)
end

# Test contract implementation
describe "Catalog service contract" do
  it "implements the contract correctly" do
    harness = create_catalog_harness
    client = ContractClient(CatalogContract).new(harness.client)
    
    # Test list_products
    products = client.list_products
    products.should be_a(Array(Product))
    products.each do |product|
      product.id.should_not be_nil
      product.name.should_not be_empty
      product.price.should be > 0
    end
    
    # Test get_product
    if products.any?
      product = client.get_product(products.first.id)
      product.should_not be_nil
      product.try(&.id).should eq(products.first.id)
    end
    
    # Test search_products
    results = client.search_products("test")
    results.should be_a(Array(Product))
    results.size.should be <= 10  # Respects limit
  end
end
```

### Provider Contract Tests

```crystal
# Verify service provides expected contract
describe "Order service as catalog consumer" do
  it "handles all catalog responses correctly" do
    # Test with various catalog responses
    test_cases = [
      # Normal response
      {
        stub_response: [{id: "1", name: "Product", price: 10.0}],
        expected_behavior: ->(order : Order) {
          order.items.first.product_name.should eq("Product")
        }
      },
      # Empty catalog
      {
        stub_response: [] of Hash(String, JSON::Any),
        expected_behavior: ->(order : Order) {
          # Should handle gracefully
        }
      },
      # Product not found
      {
        stub_response: nil,
        stub_status: 404,
        expected_error: Micro::Core::NotFoundError
      }
    ]
    
    test_cases.each do |test_case|
      catalog_mock = create_catalog_mock(
        response: test_case[:stub_response],
        status: test_case[:stub_status]? || 200
      )
      
      order_service = OrderService.new(catalog_client: catalog_mock)
      
      if expected_error = test_case[:expected_error]?
        expect_raises(expected_error) do
          order_service.create_order(sample_order_input)
        end
      else
        order = order_service.create_order(sample_order_input)
        test_case[:expected_behavior].call(order)
      end
    end
  end
end
```

## Best Practices

### 1. Test Isolation

Ensure tests don't interfere with each other:

```crystal
describe "Isolated tests" do
  # Use unique IDs for test data
  def generate_test_id
    "test-#{UUID.random}"
  end
  
  # Clean up after tests
  after_each do
    TestDataCleaner.clean_by_prefix("test-")
  end
  
  # Use separate databases/namespaces
  around_each do |example|
    with_test_database do
      example.run
    end
  end
  
  # Isolate external dependencies
  before_each do
    WebMock.reset
    TestMessageBroker.clear_messages
  end
end
```

### 2. Test Helpers

Create reusable test utilities:

```crystal
module TestHelpers
  # Generate test JWT tokens
  def generate_test_jwt(user_id : String, 
                       roles : Array(String) = ["user"],
                       exp : Time = 1.hour.from_now) : String
    payload = {
      "sub" => user_id,
      "roles" => roles,
      "exp" => exp.to_unix,
      "iat" => Time.utc.to_unix
    }
    
    JWT.encode(payload, test_jwt_secret, JWT::Algorithm::HS256)
  end
  
  # Create test users
  def create_test_user(email : String = "test@example.com") : User
    User.create(
      email: email,
      name: "Test User",
      password: "test123"
    )
  end
  
  # Wait for service ready
  def wait_for_service(service : ServiceHarness, 
                      timeout : Time::Span = 5.seconds)
    deadline = Time.monotonic + timeout
    
    loop do
      response = service.call_json("health")
      break if response.status == 200
      
      if Time.monotonic > deadline
        raise "Service failed to become ready"
      end
      
      sleep 100.milliseconds
    end
  end
  
  # Assert eventual consistency
  def eventually(timeout : Time::Span = 5.seconds, &block)
    deadline = Time.monotonic + timeout
    last_error = nil
    
    loop do
      begin
        yield
        return
      rescue ex
        last_error = ex
        
        if Time.monotonic > deadline
          raise last_error.not_nil!
        end
        
        sleep 100.milliseconds
      end
    end
  end
end
```

### 3. Test Data Builders

Use builders for complex test data:

```crystal
class TestDataBuilder
  class OrderBuilder
    property customer_id = "test-customer"
    property items = [] of OrderItem
    property shipping_address : Address? = nil
    property payment_method = "test-card"
    
    def with_customer(id : String) : self
      @customer_id = id
      self
    end
    
    def with_item(product_id : String, quantity : Int32 = 1) : self
      @items << OrderItem.new(product_id, quantity)
      self
    end
    
    def with_items(count : Int32) : self
      count.times do |i|
        with_item("product-#{i + 1}")
      end
      self
    end
    
    def with_shipping(address : Address) : self
      @shipping_address = address
      self
    end
    
    def build : CreateOrderInput
      CreateOrderInput.new(
        customer_id: @customer_id,
        items: @items,
        shipping_address: @shipping_address || default_address,
        payment_method: @payment_method
      )
    end
    
    private def default_address : Address
      Address.new(
        street: "123 Test St",
        city: "Test City",
        state: "TS",
        zip: "12345"
      )
    end
  end
  
  def self.order : OrderBuilder
    OrderBuilder.new
  end
end

# Usage
order = TestDataBuilder.order
  .with_customer("cust-123")
  .with_items(3)
  .with_shipping(test_address)
  .build
```

### 4. Assertion Helpers

Create domain-specific assertions:

```crystal
module ServiceAssertions
  def assert_successful_response(response : HTTP::Client::Response)
    response.status.should eq(200)
    response.headers["Content-Type"]?.should eq("application/json")
    response.body.should_not be_empty
  end
  
  def assert_error_response(response : HTTP::Client::Response, 
                           expected_status : Int32,
                           expected_message : String? = nil)
    response.status.should eq(expected_status)
    
    error = JSON.parse(response.body)
    error["error"]?.should_not be_nil
    
    if expected_message
      error["error"].as_s.should contain(expected_message)
    end
  end
  
  def assert_valid_product(product : JSON::Any)
    product["id"]?.should_not be_nil
    product["name"]?.should_not be_nil
    product["price"]?.should_not be_nil
    product["price"].as_f.should be > 0
  end
  
  def assert_event_published(topic : String, &block)
    events = TestMessageBroker.events_for(topic)
    initial_count = events.size
    
    yield
    
    new_events = TestMessageBroker.events_for(topic)
    new_events.size.should eq(initial_count + 1)
    
    event = new_events.last
    event
  end
end
```

### 5. Test Organization

Structure tests clearly:

```crystal
describe CatalogService do
  describe "GET /list_products" do
    context "with products in database" do
      before_each do
        create_test_products(5)
      end
      
      it "returns all products" do
        response = harness.call_json("list_products")
        products = Array(Product).from_json(response.body)
        products.size.should eq(5)
      end
      
      it "returns products sorted by name" do
        response = harness.call_json("list_products")
        products = Array(Product).from_json(response.body)
        products.should be_sorted_by(&.name)
      end
    end
    
    context "with no products" do
      it "returns empty array" do
        response = harness.call_json("list_products")
        products = Array(Product).from_json(response.body)
        products.should be_empty
      end
    end
    
    context "with pagination" do
      before_each do
        create_test_products(25)
      end
      
      it "respects limit parameter" do
        response = harness.call_json("list_products", {limit: 10})
        products = Array(Product).from_json(response.body)
        products.size.should eq(10)
      end
      
      it "respects offset parameter" do
        # Get first page
        page1 = harness.call_json("list_products", {limit: 10, offset: 0})
        products1 = Array(Product).from_json(page1.body)
        
        # Get second page
        page2 = harness.call_json("list_products", {limit: 10, offset: 10})
        products2 = Array(Product).from_json(page2.body)
        
        # Should be different products
        products1.first.id.should_not eq(products2.first.id)
      end
    end
  end
end
```

### 6. CI/CD Integration

Configure tests for continuous integration:

```crystal
# spec/spec_helper.cr
require "spec"
require "../src/micro"

# Configure for CI environment
if ENV["CI"]?
  # Use in-memory database
  DB.setup("sqlite3::memory:")
  
  # Disable external service calls
  WebMock.disable_net_connect!(allow: [
    "localhost",
    "127.0.0.1"
  ])
  
  # Set shorter timeouts
  Spec.configure do |config|
    config.fail_fast = true
    config.formatter = Spec::JUnitFormatter.new
  end
end

# Global test setup
Spec.before_suite do
  # Run migrations
  Migrator.migrate
  
  # Seed test data
  TestSeeder.seed
end

Spec.after_suite do
  # Clean up
  TestCleaner.clean_all
  
  # Generate coverage report
  if ENV["COVERAGE"]?
    Coverage.generate_report
  end
end
```

## Next Steps

- Review [Service Development](service-development.md) for testable service design
- Learn about [Monitoring](monitoring.md) test metrics
- Explore [Client Communication](client-communication.md) testing
- Set up [API Gateway](api-gateway.md) tests