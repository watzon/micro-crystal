require "../../../spec_helper"
require "../../../../src/micro/stdlib/middleware/role_guard"

describe Micro::Stdlib::Middleware::RoleGuard do
  it "denies without principal" do
    req = Micro::Core::Request.new(service: "svc", endpoint: "op")
    res = Micro::Core::Response.new
    ctx = Micro::Core::Context.new(req, res)

    mw = Micro::Stdlib::Middleware::RoleGuard.new(["admin"])
    mw.call(ctx, ->(c : Micro::Core::Context) { c.response.body = {"ok" => JSON::Any.new(true)} })
    ctx.response.status.should eq 401
  end

  it "allows when principal has role" do
    req = Micro::Core::Request.new(service: "svc", endpoint: "op")
    res = Micro::Core::Response.new
    ctx = Micro::Core::Context.new(req, res)

    role = Micro::Core::Auth::Role.new("admin")
    principal = Micro::Core::Auth::Principal.new(id: "1", username: "u1", roles: [role])
    ctx.set("auth:principal", principal)

    mw = Micro::Stdlib::Middleware::RoleGuard.new(["admin"])
    mw.call(ctx, ->(c : Micro::Core::Context) { c.response.body = {"ok" => JSON::Any.new(true)} })
    ctx.response.status.should eq 200
  end

  it "respects require_all flag" do
    req = Micro::Core::Request.new(service: "svc", endpoint: "op")
    res = Micro::Core::Response.new
    ctx = Micro::Core::Context.new(req, res)

    role = Micro::Core::Auth::Role.new("editor")
    principal = Micro::Core::Auth::Principal.new(id: "1", username: "u1", roles: [role])
    ctx.set("auth:principal", principal)

    mw = Micro::Stdlib::Middleware::RoleGuard.new(["admin", "editor"], true)
    mw.call(ctx, ->(c : Micro::Core::Context) { c.response.body = {"ok" => JSON::Any.new(true)} })
    ctx.response.status.should eq 403
  end
end


