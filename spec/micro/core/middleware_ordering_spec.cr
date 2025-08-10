require "../../spec_helper"
require "../../../src/micro/core/middleware"
require "../../../src/micro/core/context"

private class RecordingMiddleware
  include Micro::Core::Middleware
  getter name : String
  getter calls : Array(String)

  def initialize(@name : String, @calls : Array(String))
  end

  def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
    @calls << "before:#{@name}"
    next_middleware.try &.call(context)
    @calls << "after:#{@name}"
  end
end

describe Micro::Core::MiddlewareChain do
  it "runs in priority order and supports skip/require" do
    calls = [] of String
    a = RecordingMiddleware.new("a", calls)
    b = RecordingMiddleware.new("b", calls)
    c = RecordingMiddleware.new("c", calls)

    chain = Micro::Core::MiddlewareChain.new
    chain.use_named("a", a, priority: 10)
    chain.use_named("b", b, priority: 5)
    chain.use_named("c", c, priority: 1)

    ctx = Micro::Core::Context.new(
      Micro::Core::Request.new("svc", "ep"),
      Micro::Core::Response.new,
    )

    chain.execute(ctx) { |_ctx| calls << "handler" }

    # Expect highest priority first around the handler
    calls.should eq [
      "before:a", "before:b", "before:c", "handler", "after:c", "after:b", "after:a",
    ]

    # Now skip b
    calls.clear
    chain.skip("b")
    chain.execute(ctx) { |_ctx| calls << "handler" }
    calls.should eq [
      "before:a", "before:c", "handler", "after:c", "after:a",
    ]
  end
end
