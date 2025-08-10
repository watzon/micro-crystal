require "../../spec_helper"
require "../../../src/micro/stdlib/testing"

describe Micro::Stdlib::Testing::ServiceHarness do
  it "handles success response" do
    h = Micro::Stdlib::Testing::ServiceHarness.build("svc") do
      handle "ping" do |ctx|
        ctx.response.body = {"message" => "pong"}
      end
    end

    res = h.call_json("ping")
    res.status.should eq 200
    JSON.parse(String.new(res.body))["message"].as_s.should eq "pong"
  ensure
    h.try(&.stop)
  end

  it "maps BadRequestError to 400 via error handler macro" do
    h = Micro::Stdlib::Testing::ServiceHarness.build("svc2") do
      handle "bad" do |ctx|
        Micro::Macros::ErrorHandling.with_error_handling(ctx) do
          raise Micro::Core::BadRequestError.new("nope")
        end
      end
    end

    res = h.call_json("bad")
    res.status.should eq 400
    body = JSON.parse(String.new(res.body))
    body["error"].as_s.should contain("nope")
    body["type"].as_s.should eq(Micro::Core::BadRequestError.name)
  ensure
    h.try(&.stop)
  end

  it "returns 404 for unknown endpoint" do
    h = Micro::Stdlib::Testing::ServiceHarness.build("svc3") do
      # no handlers
    end

    res = h.call_json("missing")
    res.status.should eq 404
  ensure
    h.try(&.stop)
  end
end
