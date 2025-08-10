require "../../../spec_helper"
require "../../../../src/micro/stdlib/middleware/timeout_middleware"

describe Micro::Stdlib::Middleware::TimeoutMiddleware do
  it "returns 504 on handler timeout" do
    req = Micro::Core::Request.new(service: "svc", endpoint: "slow")
    res = Micro::Core::Response.new
    ctx = Micro::Core::Context.new(req, res)

    mw = Micro::Stdlib::Middleware::TimeoutMiddleware.new(50.milliseconds)
    mw.call(ctx, ->(c : Micro::Core::Context) {
      sleep 200.milliseconds
      c.response.body = {"ok" => JSON::Any.new(true)}
    })

    ctx.response.status.should eq 504
    body = JSON.parse(String.new(Micro::Core::MessageEncoder.response_body_to_bytes(ctx.response.body)))
    body["error"].as_s.should contain("timeout")
  end
end
