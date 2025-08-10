require "../../../spec_helper"
require "../../../../src/micro/stdlib/middleware/rate_limit_middleware"

describe Micro::Stdlib::Middleware::RateLimitMiddleware do
  it "limits requests and sets headers" do
    req = Micro::Core::Request.new(service: "svc", endpoint: "ping")
    res = Micro::Core::Response.new
    ctx = Micro::Core::Context.new(req, res)

    mw = Micro::Stdlib::Middleware::RateLimitMiddleware.new(limit: 2, window: 200.milliseconds)

    # Call through middleware chain runner to simulate multiple calls
    2.times do
      ctx = Micro::Core::Context.new(req, Micro::Core::Response.new)
      mw.call(ctx, ->(c : Micro::Core::Context) { c.response.body = {"ok" => JSON::Any.new(true)} })
      ctx.response.status.should eq 200
    end

    ctx3 = Micro::Core::Context.new(req, Micro::Core::Response.new)
    mw.call(ctx3, ->(c : Micro::Core::Context) { c.response.body = {"ok" => JSON::Any.new(true)} })
    ctx3.response.status.should eq 429
    ctx3.response.headers["X-RateLimit-Limit"]?.should eq "2"
    ctx3.response.headers["X-RateLimit-Remaining"]?.should eq "0"

    sleep 300.milliseconds
    ctx4 = Micro::Core::Context.new(req, Micro::Core::Response.new)
    mw.call(ctx4, ->(c : Micro::Core::Context) { c.response.body = {"ok" => JSON::Any.new(true)} })
    ctx4.response.status.should eq 200
  end
end
