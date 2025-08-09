require "../../spec_helper"
require "../../../src/micro/core/middleware"
require "../../../src/micro/core/context"
require "../../../src/micro/annotations"
require "../../../src/micro/macros/middleware_support"

describe Micro::Core::MiddlewareChain do
  describe "priority ordering" do
    it "executes middleware in priority order (highest first)" do
      order = [] of String

      low_priority = Micro::Core::Middleware.new do |ctx, next_mw|
        order << "low"
        next_mw.try(&.call(ctx))
      end

      high_priority = Micro::Core::Middleware.new do |ctx, next_mw|
        order << "high"
        next_mw.try(&.call(ctx))
      end

      medium_priority = Micro::Core::Middleware.new do |ctx, next_mw|
        order << "medium"
        next_mw.try(&.call(ctx))
      end

      chain = Micro::Core::MiddlewareChain.new
      chain.use_named("low", low_priority, -10)
      chain.use_named("high", high_priority, 100)
      chain.use_named("medium", medium_priority, 50)

      ctx = Micro::Core::Context.new(
        Micro::Core::Request.new("test", "test_method"),
        Micro::Core::Response.new
      )

      chain.execute(ctx) do |_|
        order << "handler"
      end

      order.should eq(["high", "medium", "low", "handler"])
    end
  end

  describe "skip functionality" do
    it "skips specified middleware" do
      executed = [] of String

      auth_mw = Micro::Core::Middleware.new do |ctx, next_mw|
        executed << "auth"
        next_mw.try(&.call(ctx))
      end

      logging_mw = Micro::Core::Middleware.new do |ctx, next_mw|
        executed << "logging"
        next_mw.try(&.call(ctx))
      end

      rate_limit_mw = Micro::Core::Middleware.new do |ctx, next_mw|
        executed << "rate_limit"
        next_mw.try(&.call(ctx))
      end

      chain = Micro::Core::MiddlewareChain.new
      chain.use_named("auth", auth_mw)
      chain.use_named("logging", logging_mw)
      chain.use_named("rate_limit", rate_limit_mw)
      chain.skip("auth", "rate_limit")

      ctx = Micro::Core::Context.new(
        Micro::Core::Request.new("test", "test_method"),
        Micro::Core::Response.new
      )

      chain.execute(ctx) do |_|
        executed << "handler"
      end

      executed.should eq(["logging", "handler"])
    end
  end

  describe "require functionality" do
    it "adds required middleware from registry" do
      executed = [] of String

      # Register middleware in the registry
      required_mw = Micro::Core::Middleware.new do |ctx, next_mw|
        executed << "required"
        next_mw.try(&.call(ctx))
      end

      Micro::Core::MiddlewareRegistry.register("required_auth", required_mw)

      chain = Micro::Core::MiddlewareChain.new
      chain.require("required_auth")

      ctx = Micro::Core::Context.new(
        Micro::Core::Request.new("test", "test_method"),
        Micro::Core::Response.new
      )

      chain.execute(ctx) do |_|
        executed << "handler"
      end

      executed.should eq(["required", "handler"])

      # Clean up registry
      Micro::Core::MiddlewareRegistry.clear
    end
  end

  describe "allow_anonymous functionality" do
    it "skips auth-related middleware when allow_anonymous is set" do
      executed = [] of String

      auth_mw = Micro::Core::Middleware.new do |ctx, next_mw|
        executed << "auth"
        next_mw.try(&.call(ctx))
      end

      jwt_mw = Micro::Core::Middleware.new do |ctx, next_mw|
        executed << "jwt"
        next_mw.try(&.call(ctx))
      end

      logging_mw = Micro::Core::Middleware.new do |ctx, next_mw|
        executed << "logging"
        next_mw.try(&.call(ctx))
      end

      chain = Micro::Core::MiddlewareChain.new
      chain.use_named("authentication", auth_mw)
      chain.use_named("jwt", jwt_mw)
      chain.use_named("logging", logging_mw)
      chain.allow_anonymous(true)

      ctx = Micro::Core::Context.new(
        Micro::Core::Request.new("test", "test_method"),
        Micro::Core::Response.new
      )

      chain.execute(ctx) do |_|
        executed << "handler"
      end

      executed.should eq(["logging", "handler"])
    end
  end

  describe "middleware short-circuiting" do
    it "allows middleware to stop the chain" do
      executed = [] of String

      first_mw = Micro::Core::Middleware.new do |ctx, next_mw|
        executed << "first"
        next_mw.try(&.call(ctx))
      end

      blocking_mw = Micro::Core::Middleware.new do |ctx, _|
        executed << "blocking"
        # Don't call next - this stops the chain
        ctx.response.body = "Unauthorized".to_slice
      end

      third_mw = Micro::Core::Middleware.new do |ctx, next_mw|
        executed << "third"
        next_mw.try(&.call(ctx))
      end

      chain = Micro::Core::MiddlewareChain.new
      chain.use(first_mw)
      chain.use(blocking_mw)
      chain.use(third_mw)

      ctx = Micro::Core::Context.new(
        Micro::Core::Request.new("test", "test_method"),
        Micro::Core::Response.new
      )

      chain.execute(ctx) do |_|
        executed << "handler"
      end

      executed.should eq(["first", "blocking"])
      String.new(ctx.response.body.as(Bytes)).should eq("Unauthorized")
    end
  end

  describe "complex middleware scenarios" do
    it "combines priority, skip, and require correctly" do
      executed = [] of String

      # Register some middleware in the registry
      admin_auth = Micro::Core::Middleware.new do |ctx, next_mw|
        executed << "admin_auth"
        next_mw.try(&.call(ctx))
      end

      Micro::Core::MiddlewareRegistry.register("admin_auth", admin_auth)

      # Create middleware with different priorities
      logging = Micro::Core::Middleware.new do |ctx, next_mw|
        executed << "logging"
        next_mw.try(&.call(ctx))
      end

      rate_limit = Micro::Core::Middleware.new do |ctx, next_mw|
        executed << "rate_limit"
        next_mw.try(&.call(ctx))
      end

      cors = Micro::Core::Middleware.new do |ctx, next_mw|
        executed << "cors"
        next_mw.try(&.call(ctx))
      end

      chain = Micro::Core::MiddlewareChain.new
      chain.use_named("logging", logging, 1000) # Highest priority
      chain.use_named("rate_limit", rate_limit, 500)
      chain.use_named("cors", cors, 100)
      chain.skip("rate_limit")    # Skip rate limiting
      chain.require("admin_auth") # Require admin auth

      ctx = Micro::Core::Context.new(
        Micro::Core::Request.new("test", "test_method"),
        Micro::Core::Response.new
      )

      chain.execute(ctx) do |_|
        executed << "handler"
      end

      # Should execute: logging (1000), cors (100), admin_auth (required), handler
      # Should skip: rate_limit
      executed.should eq(["logging", "cors", "admin_auth", "handler"])

      # Clean up
      Micro::Core::MiddlewareRegistry.clear
    end
  end
end

# Test the annotation processing
@[Micro::Service(name: "test_service")]
@[Micro::Middleware(["service_logging", "service_auth"])]
@[Micro::MiddlewarePriority(100)]
class TestServiceWithMiddleware
  include Micro::Macros::MiddlewareSupport

  @[Micro::Method]
  @[Micro::Middleware(["method_validation"])]
  def normal_method
    "normal"
  end

  @[Micro::Method]
  @[Micro::AllowAnonymous]
  def public_method
    "public"
  end

  @[Micro::Method]
  @[Micro::SkipMiddleware(["service_logging"])]
  def no_logging_method
    "no_logging"
  end

  @[Micro::Method]
  @[Micro::RequireMiddleware(["admin_auth"], priority: 2000)]
  def admin_only_method
    "admin"
  end
end

describe "Annotation-based middleware configuration" do
  it "processes service-level middleware annotations" do
    config = TestServiceWithMiddleware.service_middleware_config
    config.should_not be_nil

    if config
      config.middleware.map(&.name).should contain("service_logging")
      config.middleware.map(&.name).should contain("service_auth")
    end

    TestServiceWithMiddleware.service_priority.should eq(100)
  end

  it "processes @[AllowAnonymous] annotation" do
    TestServiceWithMiddleware.allows_anonymous?("public_method").should be_true
    TestServiceWithMiddleware.allows_anonymous?("normal_method").should be_false
  end

  it "processes @[SkipMiddleware] annotation" do
    config = TestServiceWithMiddleware.method_middleware_configs["no_logging_method"]?
    config.should_not be_nil

    if config
      config.skip.should contain("service_logging")
    end
  end

  it "processes @[RequireMiddleware] annotation" do
    config = TestServiceWithMiddleware.method_middleware_configs["admin_only_method"]?
    config.should_not be_nil

    if config
      config.require.should contain("admin_auth")
      config.priority.should eq(2000)
    end
  end

  it "builds correct middleware chain for methods" do
    # Register test middleware
    test_middleware = {} of String => Micro::Core::Middleware

    ["service_logging", "service_auth", "method_validation", "admin_auth"].each do |name|
      test_middleware[name] = Micro::Core::Middleware.new do |ctx, next_mw|
        ctx.set("executed_#{name}", true)
        next_mw.try(&.call(ctx))
      end
      Micro::Core::MiddlewareRegistry.register(name, test_middleware[name])
    end

    # Test normal method chain
    chain = TestServiceWithMiddleware.build_middleware_chain("normal_method")
    chain.should_not be_nil

    if chain
      ctx = Micro::Core::Context.new(
        Micro::Core::Request.new("test", "test_method"),
        Micro::Core::Response.new
      )

      chain.execute(ctx, &.set("handler_executed", true))

      ctx.get("executed_service_logging", Bool).should be_true
      ctx.get("executed_service_auth", Bool).should be_true
      ctx.get("executed_method_validation", Bool).should be_true
      ctx.get("handler_executed", Bool).should be_true
    end

    # Clean up
    Micro::Core::MiddlewareRegistry.clear
  end
end
