require "../../../spec_helper"
require "../../../../src/micro/stdlib/middleware/jwt_auth_middleware"

private def make_jwt(payload : Hash(String, JSON::Any), secret : String) : String
  header = {"alg" => "HS256", "typ" => "JWT"}.to_json
  body = payload.to_json
  JWT.encode(JSON.parse(body), secret, JWT::Algorithm::HS256)
end

describe Micro::Stdlib::Middleware::JWTAuthMiddleware do
  it "rejects missing token with 401" do
    req = Micro::Core::Request.new(service: "svc", endpoint: "op")
    res = Micro::Core::Response.new
    ctx = Micro::Core::Context.new(req, res)

    mw = Micro::Stdlib::Middleware::JWTAuthMiddleware.new(secret: "secret", algorithm: JWT::Algorithm::HS256)
    # Build a tiny chain to let post-processing run
    next_proc = ->(c : Micro::Core::Context) { c.response.body = {"ok" => JSON::Any.new(true)} }
    mw.call(ctx, next_proc)

    ctx.response.status.should eq 401
  end

  it "rejects invalid signature" do
    token = make_jwt({"sub" => JSON::Any.new("u1"), "exp" => JSON::Any.new((Time.utc + 1.hour).to_unix)}, "wrong")
    req = Micro::Core::Request.new(service: "svc", endpoint: "op")
    req.headers["Authorization"] = "Bearer #{token}"
    res = Micro::Core::Response.new
    ctx = Micro::Core::Context.new(req, res)

    mw = Micro::Stdlib::Middleware::JWTAuthMiddleware.new(secret: "secret", algorithm: JWT::Algorithm::HS256)
    next_proc = ->(c : Micro::Core::Context) { c.response.body = {"ok" => JSON::Any.new(true)} }
    mw.call(ctx, next_proc)

    ctx.response.status.should eq 401
  end

  it "accepts valid token and sets context attributes" do
    token = make_jwt({"sub" => JSON::Any.new("u1"), "exp" => JSON::Any.new((Time.utc + 1.hour).to_unix)}, "secret")
    req = Micro::Core::Request.new(service: "svc", endpoint: "op")
    req.headers["Authorization"] = "Bearer #{token}"
    res = Micro::Core::Response.new
    ctx = Micro::Core::Context.new(req, res)

    mw = Micro::Stdlib::Middleware::JWTAuthMiddleware.new(secret: "secret", algorithm: JWT::Algorithm::HS256)
    next_proc = ->(c : Micro::Core::Context) { c.response.body = {"ok" => JSON::Any.new(true)} }
    mw.call(ctx, next_proc)

    ctx.response.status.should eq 200
    ctx.get("user", String).should eq "u1"
    ctx.get("jwt_claims", JSON::Any).should_not be_nil
  end

  it "rejects expired token" do
    token = make_jwt({"sub" => JSON::Any.new("u1"), "exp" => JSON::Any.new((Time.utc - 1.hour).to_unix)}, "secret")
    req = Micro::Core::Request.new(service: "svc", endpoint: "op")
    req.headers["Authorization"] = "Bearer #{token}"
    res = Micro::Core::Response.new
    ctx = Micro::Core::Context.new(req, res)

    mw = Micro::Stdlib::Middleware::JWTAuthMiddleware.new(secret: "secret", algorithm: JWT::Algorithm::HS256)
    next_proc = ->(c : Micro::Core::Context) { c.response.body = {"ok" => JSON::Any.new(true)} }
    mw.call(ctx, next_proc)

    ctx.response.status.should eq 401
  end
end
