require "../../../spec_helper"
require "../../../../src/micro/stdlib/middleware/recovery_middleware"

describe Micro::Stdlib::Middleware::RecoveryMiddleware do
  it "catches exceptions and returns 500" do
    req = Micro::Core::Request.new(service: "svc", endpoint: "boom")
    res = Micro::Core::Response.new
    ctx = Micro::Core::Context.new(req, res)

    mw = Micro::Stdlib::Middleware::RecoveryMiddleware.new
    mw.call(ctx, ->(_c : Micro::Core::Context) { raise "kaboom" })

    ctx.response.status.should eq 500
    body = JSON.parse(String.new(Micro::Core::MessageEncoder.response_body_to_bytes(ctx.response.body)))
    body["error"].as_s.should contain("Internal server error")
  end
end
