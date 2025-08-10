require "../../../spec_helper"
require "../../../../src/micro/stdlib/middleware/request_size_middleware"

describe Micro::Stdlib::Middleware::RequestSizeMiddleware do
  it "returns 413 when content-length exceeds limit" do
    req = Micro::Core::Request.new(service: "svc", endpoint: "upload")
    req.headers["Content-Length"] = "10"
    req.headers["Path"] = "/upload"
    res = Micro::Core::Response.new
    ctx = Micro::Core::Context.new(req, res)

    mw = Micro::Stdlib::Middleware::RequestSizeMiddleware.new(max_size: 5_i64)
    mw.call(ctx, ->(c : Micro::Core::Context) { c.response.body = {"ok" => JSON::Any.new(true)} })

    ctx.response.status.should eq 413
    body = JSON.parse(String.new(Micro::Core::MessageEncoder.response_body_to_bytes(ctx.response.body)))
    body["error"].as_s.should contain("exceeds")
  end

  it "allows small requests under the limit" do
    req = Micro::Core::Request.new(service: "svc", endpoint: "upload")
    req.headers["Content-Length"] = "1"
    req.headers["Path"] = "/upload"
    res = Micro::Core::Response.new
    ctx = Micro::Core::Context.new(req, res)

    mw = Micro::Stdlib::Middleware::RequestSizeMiddleware.new(max_size: 100_i64)
    mw.call(ctx, ->(c : Micro::Core::Context) { c.response.body = {"ok" => JSON::Any.new(true)} })

    ctx.response.status.should eq 200
  end
end
