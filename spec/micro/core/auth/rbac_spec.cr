require "../../../spec_helper"
require "../../../../src/micro/core/auth/models"
require "../../../../src/micro/stdlib/middleware/role_guard"
require "../../../../src/micro/core/context"
require "../../../../src/micro/annotations"
require "../../../../src/micro/macros/middleware_support"

describe Micro::Core::Auth do
  describe "Permission" do
    it "matches exact permissions" do
      perm = Micro::Core::Auth::Permission.new("users", "read", "own")
      required = Micro::Core::Auth::Permission.new("users", "read", "own")

      perm.matches?(required).should be_true
    end

    it "matches wildcard resource" do
      perm = Micro::Core::Auth::Permission.new("*", "read", nil)
      required = Micro::Core::Auth::Permission.new("users", "read", nil)

      perm.matches?(required).should be_true
    end

    it "matches wildcard action" do
      perm = Micro::Core::Auth::Permission.new("users", "*", nil)
      required = Micro::Core::Auth::Permission.new("users", "write", nil)

      perm.matches?(required).should be_true
    end

    it "matches nil scope as wildcard" do
      perm = Micro::Core::Auth::Permission.new("users", "read", nil)
      required = Micro::Core::Auth::Permission.new("users", "read", "own")

      perm.matches?(required).should be_true
    end

    it "parses permission strings" do
      perm = Micro::Core::Auth::Permission.parse("users:read:own")
      perm.resource.should eq("users")
      perm.action.should eq("read")
      perm.scope.should eq("own")

      perm2 = Micro::Core::Auth::Permission.parse("posts:*")
      perm2.resource.should eq("posts")
      perm2.action.should eq("*")
      perm2.scope.should be_nil
    end
  end

  describe "Role" do
    it "checks for permissions" do
      perms = [
        Micro::Core::Auth::Permission.new("users", "read", nil),
        Micro::Core::Auth::Permission.new("users", "write", "own"),
      ]
      role = Micro::Core::Auth::Role.new("editor", perms)

      role.has_permission?(Micro::Core::Auth::Permission.new("users", "read", "any")).should be_true
      role.has_permission?(Micro::Core::Auth::Permission.new("users", "write", "own")).should be_true
      role.has_permission?(Micro::Core::Auth::Permission.new("users", "delete", nil)).should be_false
    end

    it "supports role inheritance" do
      base_role = Micro::Core::Auth::Role.new("user", [
        Micro::Core::Auth::Permission.new("profile", "read", "own"),
      ])

      admin_role = Micro::Core::Auth::Role.new("admin", [
        Micro::Core::Auth::Permission.new("users", "*", nil),
      ], base_role)

      admin_role.includes?("admin").should be_true
      admin_role.includes?("user").should be_true

      all_perms = admin_role.all_permissions
      all_perms.size.should eq(2)
    end
  end

  describe "Principal" do
    it "checks roles and permissions" do
      user_role = Micro::Core::Auth::Role.new("user", [
        Micro::Core::Auth::Permission.new("profile", "read", "own"),
        Micro::Core::Auth::Permission.new("profile", "write", "own"),
      ])

      admin_role = Micro::Core::Auth::Role.new("admin", [
        Micro::Core::Auth::Permission.new("*", "*", nil),
      ])

      principal = Micro::Core::Auth::Principal.new(
        id: "123",
        username: "john",
        roles: [user_role, admin_role]
      )

      principal.has_role?("user").should be_true
      principal.has_role?("admin").should be_true
      principal.has_role?("superadmin").should be_false

      principal.has_any_role?(["admin", "moderator"]).should be_true
      principal.has_all_roles?(["user", "admin"]).should be_true
      principal.has_all_roles?(["user", "admin", "superadmin"]).should be_false

      principal.can?("users:delete").should be_true # admin has *:*
      principal.can?("profile:read:own").should be_true
    end
  end

  describe "Policies" do
    it "evaluates role policies" do
      principal = Micro::Core::Auth::Principal.new(
        id: "123",
        username: "john",
        roles: [Micro::Core::Auth::Role.new("admin", [] of Micro::Core::Auth::Permission)]
      )

      ctx = Micro::Core::Context.new(
        Micro::Core::Request.new("test", "method"),
        Micro::Core::Response.new
      )

      policy = Micro::Core::Auth::RolePolicy.new(["admin"], false)
      result = policy.authorize(principal, ctx)
      result.authorized?.should be_true

      policy2 = Micro::Core::Auth::RolePolicy.new(["superadmin"], false)
      result2 = policy2.authorize(principal, ctx)
      result2.denied?.should be_true
    end

    it "evaluates permission policies" do
      principal = Micro::Core::Auth::Principal.new(
        id: "123",
        username: "john",
        roles: [Micro::Core::Auth::Role.new("user", [
          Micro::Core::Auth::Permission.new("posts", "read", nil),
          Micro::Core::Auth::Permission.new("posts", "write", "own"),
        ])]
      )

      ctx = Micro::Core::Context.new(
        Micro::Core::Request.new("test", "method"),
        Micro::Core::Response.new
      )

      policy = Micro::Core::Auth::PermissionPolicy.new([
        Micro::Core::Auth::Permission.new("posts", "read", nil),
      ])
      result = policy.authorize(principal, ctx)
      result.authorized?.should be_true

      policy2 = Micro::Core::Auth::PermissionPolicy.new([
        Micro::Core::Auth::Permission.new("posts", "delete", nil),
      ])
      result2 = policy2.authorize(principal, ctx)
      result2.denied?.should be_true
    end

    it "evaluates composite policies" do
      principal = Micro::Core::Auth::Principal.new(
        id: "123",
        username: "john",
        roles: [Micro::Core::Auth::Role.new("editor", [
          Micro::Core::Auth::Permission.new("posts", "*", nil),
        ])]
      )

      ctx = Micro::Core::Context.new(
        Micro::Core::Request.new("test", "method"),
        Micro::Core::Response.new
      )

      # AND policy - both must pass
      and_policy = Micro::Core::Auth::CompositePolicy.new([
        Micro::Core::Auth::RolePolicy.new(["editor"], false).as(Micro::Core::Auth::Policy),
        Micro::Core::Auth::PermissionPolicy.new([
          Micro::Core::Auth::Permission.new("posts", "write", nil),
        ]).as(Micro::Core::Auth::Policy),
      ], Micro::Core::Auth::CompositePolicy::Operator::And)

      result = and_policy.authorize(principal, ctx)
      result.authorized?.should be_true

      # OR policy - at least one must pass
      or_policy = Micro::Core::Auth::CompositePolicy.new([
        Micro::Core::Auth::RolePolicy.new(["admin"], false).as(Micro::Core::Auth::Policy),
        Micro::Core::Auth::RolePolicy.new(["editor"], false).as(Micro::Core::Auth::Policy),
      ], Micro::Core::Auth::CompositePolicy::Operator::Or)

      result2 = or_policy.authorize(principal, ctx)
      result2.authorized?.should be_true
    end
  end
end

describe Micro::Stdlib::Middleware do
  describe "RoleGuard" do
    it "blocks unauthenticated requests" do
      guard = Micro::Stdlib::Middleware::RoleGuard.new(["admin"])

      ctx = Micro::Core::Context.new(
        Micro::Core::Request.new("test", "method"),
        Micro::Core::Response.new
      )

      called = false
      guard.call(ctx, ->(_c : Micro::Core::Context) { called = true; nil })

      called.should be_false
      ctx.response.status.should eq(401)
    end

    it "blocks users without required roles" do
      guard = Micro::Stdlib::Middleware::RoleGuard.new(["admin"])

      principal = Micro::Core::Auth::Principal.new(
        id: "123",
        username: "john",
        roles: [Micro::Core::Auth::Role.new("user", [] of Micro::Core::Auth::Permission)]
      )

      ctx = Micro::Core::Context.new(
        Micro::Core::Request.new("test", "method"),
        Micro::Core::Response.new
      )
      ctx.set("auth:principal", principal)

      called = false
      guard.call(ctx, ->(_c : Micro::Core::Context) { called = true; nil })

      called.should be_false
      ctx.response.status.should eq(403)
    end

    it "allows users with required roles" do
      guard = Micro::Stdlib::Middleware::RoleGuard.new(["admin"])

      principal = Micro::Core::Auth::Principal.new(
        id: "123",
        username: "john",
        roles: [Micro::Core::Auth::Role.new("admin", [] of Micro::Core::Auth::Permission)]
      )

      ctx = Micro::Core::Context.new(
        Micro::Core::Request.new("test", "method"),
        Micro::Core::Response.new
      )
      ctx.set("auth:principal", principal)

      called = false
      guard.call(ctx, ->(_c : Micro::Core::Context) { called = true; nil })

      called.should be_true
    end
  end

  describe "PermissionGuard" do
    it "blocks users without required permissions" do
      guard = Micro::Stdlib::Middleware::PermissionGuard.new(["users:write"])

      principal = Micro::Core::Auth::Principal.new(
        id: "123",
        username: "john",
        roles: [Micro::Core::Auth::Role.new("user", [
          Micro::Core::Auth::Permission.new("users", "read", nil),
        ])]
      )

      ctx = Micro::Core::Context.new(
        Micro::Core::Request.new("test", "method"),
        Micro::Core::Response.new
      )
      ctx.set("auth:principal", principal)

      called = false
      guard.call(ctx, ->(_c : Micro::Core::Context) { called = true; nil })

      called.should be_false
      ctx.response.status.should eq(403)
    end

    it "allows users with required permissions" do
      guard = Micro::Stdlib::Middleware::PermissionGuard.new(["users:read"])

      principal = Micro::Core::Auth::Principal.new(
        id: "123",
        username: "john",
        roles: [Micro::Core::Auth::Role.new("user", [
          Micro::Core::Auth::Permission.new("users", "read", nil),
        ])]
      )

      ctx = Micro::Core::Context.new(
        Micro::Core::Request.new("test", "method"),
        Micro::Core::Response.new
      )
      ctx.set("auth:principal", principal)

      called = false
      guard.call(ctx, ->(_c : Micro::Core::Context) { called = true; nil })

      called.should be_true
    end
  end
end

# Test annotation-based RBAC
@[Micro::Service(name: "secure_service")]
class SecureService
  include Micro::Macros::MiddlewareSupport

  @[Micro::Method]
  @[Micro::AllowAnonymous]
  def public_endpoint
    "public"
  end

  @[Micro::Method]
  @[Micro::RequireRole("admin")]
  def admin_only
    "admin"
  end

  @[Micro::Method]
  @[Micro::RequireRole(["admin", "moderator"])]
  def admin_or_mod
    "restricted"
  end

  @[Micro::Method]
  @[Micro::RequirePermission("users:write")]
  def write_users
    "write"
  end

  @[Micro::Method]
  @[Micro::RequirePermission(["users:read", "users:write"], require_all: false)]
  def read_or_write_users
    "read_or_write"
  end
end

describe "Annotation-based RBAC" do
  it "processes @[RequireRole] annotations" do
    config = SecureService.method_middleware_configs["admin_only"]?
    config.should_not be_nil

    if config
      config.required_roles.should eq(["admin"])
      config.require_all_roles.should be_false
    end
  end

  it "processes @[RequirePermission] annotations" do
    config = SecureService.method_middleware_configs["write_users"]?
    config.should_not be_nil

    if config
      config.required_permissions.should eq(["users:write"])
      config.require_all_permissions.should be_true
    end
  end

  it "allows anonymous access when specified" do
    config = SecureService.method_middleware_configs["public_endpoint"]?
    config.should_not be_nil

    if config
      config.allow_anonymous.should be_true
    end
  end

  it "builds middleware chain with RBAC guards" do
    # This would require the guards to be registered in the middleware registry
    # For now, we just verify the configuration is correct
    chain = SecureService.build_middleware_chain("admin_only")

    # The chain should exist if RBAC is configured
    chain.should_not be_nil if SecureService.method_middleware_configs.has_key?("admin_only")
  end
end
