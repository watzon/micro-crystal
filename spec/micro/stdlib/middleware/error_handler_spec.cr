require "../../../spec_helper"
require "../../../../src/micro/stdlib/middleware/error_handler_middleware"

describe Micro::Stdlib::Middleware::ErrorHandlerMiddleware do
  it "maps ArgumentError to 400 and formats error body" do
    req = Micro::Core::Request.new(service: "svc", endpoint: "op")
    res = Micro::Core::Response.new
    ctx = Micro::Core::Context.new(req, res)

    mw = Micro::Stdlib::Middleware::ErrorHandlerMiddleware.new
    mw.call(ctx, ->(c : Micro::Core::Context) { raise ArgumentError.new("bad") })

    ctx.response.status.should eq 400
    body = JSON.parse(String.new(Micro::Core::MessageEncoder.response_body_to_bytes(ctx.response.body)))
    body["type"].as_s.should eq "ArgumentError"
  end
end


