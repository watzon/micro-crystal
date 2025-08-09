require "../../core/middleware"
require "../../core/context"
require "../../core/auth/models"

module Micro::Stdlib::Middleware
  # Middleware that enforces role-based access control
  class RoleGuard
    include Micro::Core::Middleware

    PRINCIPAL_KEY = "auth:principal"

    getter required_roles : Array(String)
    getter require_all : Bool

    def initialize(@required_roles : Array(String), @require_all = false)
    end

    def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
      # Get the authenticated principal from context
      principal = context.get(PRINCIPAL_KEY, Micro::Core::Auth::Principal)

      # No principal means not authenticated
      unless principal
        context.response.status = 401
        context.response.body = {"error" => "Authentication required"}.to_json.to_slice
        context.response.headers["Content-Type"] = "application/json"
        return
      end

      # Check roles
      has_roles = if @require_all
                    principal.has_all_roles?(@required_roles)
                  else
                    principal.has_any_role?(@required_roles)
                  end

      unless has_roles
        context.response.status = 403
        context.response.body = {
          "error"          => "Insufficient privileges",
          "required_roles" => @required_roles,
          "require_all"    => @require_all,
        }.to_json.to_slice
        context.response.headers["Content-Type"] = "application/json"
        return
      end

      # Authorized - continue chain
      next_middleware.try(&.call(context))
    end

    # Factory method for registry
    def self.from_config(config : Hash(String, JSON::Any)) : RoleGuard
      roles = config["roles"]?.try do |r|
        case r
        when String
          [r.as_s]
        when Array
          r.as_a.map(&.as_s)
        else
          raise ArgumentError.new("Invalid roles configuration")
        end
      end || [] of String

      require_all = config["require_all"]?.try(&.as_bool) || false

      new(roles, require_all)
    end
  end

  # Middleware that enforces permission-based access control
  class PermissionGuard
    include Micro::Core::Middleware

    PRINCIPAL_KEY = "auth:principal"

    getter required_permissions : Array(Micro::Core::Auth::Permission)
    getter require_all : Bool

    def initialize(permissions : Array(String), @require_all = true)
      @required_permissions = permissions.map { |p| Micro::Core::Auth::Permission.parse(p) }
    end

    def initialize(@required_permissions : Array(Micro::Core::Auth::Permission), @require_all = true)
    end

    def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
      # Get the authenticated principal from context
      principal = context.get(PRINCIPAL_KEY, Micro::Core::Auth::Principal)

      # No principal means not authenticated
      unless principal
        context.response.status = 401
        context.response.body = {"error" => "Authentication required"}.to_json.to_slice
        context.response.headers["Content-Type"] = "application/json"
        return
      end

      # Check permissions
      has_perms = if @require_all
                    @required_permissions.all? { |p| principal.has_permission?(p) }
                  else
                    @required_permissions.any? { |p| principal.has_permission?(p) }
                  end

      unless has_perms
        context.response.status = 403
        context.response.body = {
          "error"                => "Insufficient privileges",
          "required_permissions" => @required_permissions.map(&.to_s),
          "require_all"          => @require_all,
        }.to_json.to_slice
        context.response.headers["Content-Type"] = "application/json"
        return
      end

      # Authorized - continue chain
      next_middleware.try(&.call(context))
    end

    # Factory method for registry
    def self.from_config(config : Hash(String, JSON::Any)) : PermissionGuard
      permissions = config["permissions"]?.try do |p|
        case p
        when String
          [p.as_s]
        when Array
          p.as_a.map(&.as_s)
        else
          raise ArgumentError.new("Invalid permissions configuration")
        end
      end || [] of String

      require_all = config["require_all"]?.try(&.as_bool) || true

      new(permissions, require_all)
    end
  end

  # Middleware that enforces policy-based access control
  class PolicyGuard
    include Micro::Core::Middleware

    PRINCIPAL_KEY = "auth:principal"

    getter policy : Micro::Core::Auth::Policy

    def initialize(@policy : Micro::Core::Auth::Policy)
    end

    def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
      # Get the authenticated principal from context
      principal = context.get(PRINCIPAL_KEY, Micro::Core::Auth::Principal)

      # No principal means not authenticated
      unless principal
        context.response.status = 401
        context.response.body = {"error" => "Authentication required"}.to_json.to_slice
        context.response.headers["Content-Type"] = "application/json"
        return
      end

      # Check policy
      result = @policy.authorize(principal, context)

      unless result.authorized?
        context.response.status = 403
        body = {"error" => "Access denied"}
        body["reason"] = result.reason.not_nil! if result.reason
        context.response.body = body.to_json.to_slice
        context.response.headers["Content-Type"] = "application/json"
        return
      end

      # Authorized - continue chain
      next_middleware.try(&.call(context))
    end

    # Factory method for creating from policy name
    def self.from_policy_name(policy_name : String, params : Hash(String, JSON::Any)? = nil) : PolicyGuard
      # This would typically look up the policy from a registry
      # For now, we'll support built-in policies
      policy = case policy_name
               when "RolePolicy"
                 roles = params.try(&.["roles"]?).try do |r|
                   case r
                   when String
                     [r.as_s]
                   when Array
                     r.as_a.map(&.as_s)
                   else
                     [] of String
                   end
                 end || [] of String

                 require_all = params.try(&.["require_all"]?).try(&.as_bool) || false
                 Micro::Core::Auth::RolePolicy.new(roles, require_all)
               when "PermissionPolicy"
                 perms = params.try(&.["permissions"]?).try do |p|
                   case p
                   when String
                     [Micro::Core::Auth::Permission.parse(p.as_s)]
                   when Array
                     p.as_a.map { |s| Micro::Core::Auth::Permission.parse(s.as_s) }
                   else
                     [] of Micro::Core::Auth::Permission
                   end
                 end || [] of Micro::Core::Auth::Permission

                 require_all = params.try(&.["require_all"]?).try(&.as_bool) || true
                 Micro::Core::Auth::PermissionPolicy.new(perms, require_all)
               else
                 raise ArgumentError.new("Unknown policy: #{policy_name}")
               end

      new(policy)
    end
  end
end
