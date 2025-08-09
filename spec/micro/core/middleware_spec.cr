require "../../spec_helper"
require "../../../src/micro/core/middleware"
require "../../../src/micro/core/context"
require "../../../src/micro/core/box"

describe Micro::Core::Middleware do
  describe "basic middleware functionality" do
    it "can create middleware from blocks" do
      called = false

      middleware = Micro::Core::Middleware.new do |context, next_handler|
        called = true
        context.set("test", "value")
        next_handler.try(&.call(context))
      end

      context = create_test_context
      middleware.call(context, nil)

      called.should be_true
      context.get("test", String).should eq("value")
    end
  end

  describe Micro::Core::MiddlewareChain do
    it "executes middleware in order" do
      order = [] of Int32

      middleware1 = Micro::Core::Middleware.new do |context, next_handler|
        order << 1
        next_handler.try(&.call(context))
        order << 4
      end

      middleware2 = Micro::Core::Middleware.new do |context, next_handler|
        order << 2
        next_handler.try(&.call(context))
        order << 3
      end

      chain = Micro::Core::MiddlewareChain.new
      chain.use(middleware1)
      chain.use(middleware2)

      context = create_test_context
      chain.execute(context) do |_|
        # Final handler
        order << 0
      end

      order.should eq([1, 2, 0, 3, 4])
    end

    it "allows middleware to short-circuit the chain" do
      executed = [] of String

      middleware1 = Micro::Core::Middleware.new do |context, _|
        executed << "middleware1"
        # Don't call next - short circuit
        context.response.status = 401
      end

      middleware2 = Micro::Core::Middleware.new do |context, next_handler|
        executed << "middleware2"
        next_handler.try(&.call(context))
      end

      chain = Micro::Core::MiddlewareChain.new
      chain.use(middleware1)
      chain.use(middleware2)

      context = create_test_context
      chain.execute(context) do |_|
        executed << "handler"
      end

      executed.should eq(["middleware1"])
      context.response.status.should eq(401)
    end

    it "supports adding multiple middleware at once" do
      count = 0

      middleware1 = Micro::Core::Middleware.new { |context, next_handler| count += 1; next_handler.try(&.call(context)) }
      middleware2 = Micro::Core::Middleware.new { |context, next_handler| count += 1; next_handler.try(&.call(context)) }
      middleware3 = Micro::Core::Middleware.new { |context, next_handler| count += 1; next_handler.try(&.call(context)) }

      chain = Micro::Core::MiddlewareChain.new
      chain.use(middleware1, middleware2, middleware3)

      chain.size.should eq(3)

      context = create_test_context
      chain.execute(context) { }

      count.should eq(3)
    end

    it "can prepend and append middleware" do
      order = [] of String

      middleware_a = Micro::Core::Middleware.new { |context, next_handler| order << "A"; next_handler.try(&.call(context)) }
      middleware_b = Micro::Core::Middleware.new { |context, next_handler| order << "B"; next_handler.try(&.call(context)) }
      middleware_c = Micro::Core::Middleware.new { |context, next_handler| order << "C"; next_handler.try(&.call(context)) }

      chain = Micro::Core::MiddlewareChain.new
      chain.use(middleware_b)

      # Prepend A, append C
      new_chain = chain.prepend(middleware_a).append(middleware_c)

      context = create_test_context
      new_chain.execute(context) { }

      order.should eq(["A", "B", "C"])
    end

    it "can merge chains" do
      order = [] of String

      chain1 = Micro::Core::MiddlewareChain.new
      chain1.use(Micro::Core::Middleware.new { |context, next_handler| order << "1"; next_handler.try(&.call(context)) })

      chain2 = Micro::Core::MiddlewareChain.new
      chain2.use(Micro::Core::Middleware.new { |context, next_handler| order << "2"; next_handler.try(&.call(context)) })

      merged = chain1 + chain2

      context = create_test_context
      merged.execute(context) { }

      order.should eq(["1", "2"])
    end
  end

  describe Micro::Core::MiddlewareRegistry do
    it "can register and retrieve middleware" do
      Micro::Core::MiddlewareRegistry.clear

      test_middleware = Micro::Core::Middleware.new do |context, next_handler|
        context.set("registered", true)
        next_handler.try(&.call(context))
      end

      Micro::Core::MiddlewareRegistry.register("test", test_middleware)

      retrieved = Micro::Core::MiddlewareRegistry.get("test")
      retrieved.should_not be_nil

      context = create_test_context
      retrieved.try(&.call(context, nil))

      context.get("registered", Bool).should be_true
    end

    it "can register middleware factories" do
      Micro::Core::MiddlewareRegistry.clear

      Micro::Core::MiddlewareRegistry.register_factory("configurable") do |options|
        value = options["value"]?.try(&.as_s) || "default"

        Micro::Core::Middleware.new do |context, next_handler|
          context.set("config_value", value)
          next_handler.try(&.call(context))
        end
      end

      # Get with options
      middleware = Micro::Core::MiddlewareRegistry.get("configurable", {"value" => JSON::Any.new("custom")})
      middleware.should_not be_nil

      context = create_test_context
      middleware.try(&.call(context, nil))

      context.get("config_value", String).should eq("custom")
    end

    it "builds chains from names" do
      Micro::Core::MiddlewareRegistry.clear

      Micro::Core::MiddlewareRegistry.register("first",
        Micro::Core::Middleware.new { |context, next_handler| context.set("first", true); next_handler.try(&.call(context)) }
      )
      Micro::Core::MiddlewareRegistry.register("second",
        Micro::Core::Middleware.new { |context, next_handler| context.set("second", true); next_handler.try(&.call(context)) }
      )

      chain = Micro::Core::MiddlewareRegistry.build_chain(["first", "second"])

      context = create_test_context
      chain.execute(context) { }

      context.get("first", Bool).should be_true
      context.get("second", Bool).should be_true
    end

    it "raises for unknown middleware" do
      Micro::Core::MiddlewareRegistry.clear

      expect_raises(Exception, "Middleware not found: unknown") do
        Micro::Core::MiddlewareRegistry.get!("unknown")
      end
    end
  end

  describe "Context extensions" do
    it "can store and retrieve typed attributes" do
      context = create_test_context

      # Store different types
      context.set("string", "hello")
      context.set("number", 42)
      context.set("bool", true)
      context.set("array", [1, 2, 3])

      # Retrieve with type safety
      context.get("string", String).should eq("hello")
      context.get("number", Int32).should eq(42)
      context.get("bool", Bool).should be_true
      context.get("array", Array(Int32)).should eq([1, 2, 3])

      # Wrong type returns nil
      context.get("string", Int32).should be_nil

      # Missing key returns nil
      context.get("missing", String).should be_nil
    end

    it "raises for missing required attributes" do
      context = create_test_context

      expect_raises(ArgumentError, "Missing or invalid context attribute: required (expected String)") do
        context.get!("required", String)
      end
    end

    it "can check and delete attributes" do
      context = create_test_context

      context.has?("test").should be_false

      context.set("test", "value")
      context.has?("test").should be_true

      deleted = context.delete("test")
      deleted.should_not be_nil

      context.has?("test").should be_false
    end
  end
end

# Helper to create test context
private def create_test_context
  request = Micro::Core::Request.new(
    service: "test",
    endpoint: "/test",
    content_type: "application/json"
  )
  response = Micro::Core::Response.new
  Micro::Core::Context.new(request, response)
end
