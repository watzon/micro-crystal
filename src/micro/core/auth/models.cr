# Authorization models for role-based access control
module Micro::Core::Auth
  # Represents a permission that can be checked
  struct Permission
    getter resource : String
    getter action : String
    getter scope : String?

    def initialize(@resource : String, @action : String, @scope : String? = nil)
    end

    # Check if this permission matches a required permission
    def matches?(required : Permission) : Bool
      return false unless resource == required.resource || resource == "*"
      return false unless action == required.action || action == "*"

      # Scope matching (nil scope = all scopes)
      return true if scope.nil?
      return true if required.scope.nil?
      scope == required.scope || scope == "*"
    end

    # String representation for debugging
    def to_s(io)
      io << resource << ":" << action
      io << ":" << scope if scope
    end

    # Parse permission from string format "resource:action:scope"
    def self.parse(str : String) : Permission
      parts = str.split(":", 3)
      raise ArgumentError.new("Invalid permission format: #{str}") if parts.empty?

      resource = parts[0]
      action = parts[1]? || "*"
      scope = parts[2]?

      new(resource, action, scope)
    end
  end

  # Represents a role with permissions
  class Role
    getter name : String
    getter permissions : Array(Permission)
    getter parent : Role?

    def initialize(@name : String, @permissions = [] of Permission, @parent : Role? = nil)
    end

    # Check if role has a specific permission
    def has_permission?(required : Permission) : Bool
      # Check own permissions
      permissions.any?(&.matches?(required))
    end

    # Check if role has all required permissions
    def has_permissions?(required : Array(Permission)) : Bool
      required.all? { |p| has_permission?(p) }
    end

    # Get all permissions including inherited ones
    def all_permissions : Array(Permission)
      own = permissions.dup
      if p = parent
        own + p.all_permissions
      else
        own
      end
    end

    # Check if this role includes another role (inheritance check)
    def includes?(role_name : String) : Bool
      return true if name == role_name
      parent.try(&.includes?(role_name)) || false
    end
  end

  # Represents an authenticated user with roles
  class Principal
    getter id : String
    getter username : String
    getter roles : Array(Role)
    getter attributes : Hash(String, String)

    def initialize(
      @id : String,
      @username : String,
      @roles = [] of Role,
      @attributes = {} of String => String,
    )
    end

    # Check if user has a specific role
    def has_role?(role_name : String) : Bool
      roles.any?(&.includes?(role_name))
    end

    # Check if user has any of the specified roles
    def has_any_role?(role_names : Array(String)) : Bool
      role_names.any? { |name| has_role?(name) }
    end

    # Check if user has all specified roles
    def has_all_roles?(role_names : Array(String)) : Bool
      role_names.all? { |name| has_role?(name) }
    end

    # Check if user has a specific permission
    def has_permission?(permission : Permission) : Bool
      roles.any?(&.has_permission?(permission))
    end

    # Check if user has permission string (e.g., "users:read:own")
    def can?(permission_str : String) : Bool
      permission = Permission.parse(permission_str)
      has_permission?(permission)
    end

    # Get all permissions from all roles
    def all_permissions : Array(Permission)
      roles.flat_map(&.all_permissions).uniq!
    end
  end

  # Authorization result with optional reason
  struct AuthorizationResult
    getter authorized : Bool
    getter reason : String?

    def initialize(@authorized : Bool, @reason : String? = nil)
    end

    def self.allow
      new(true)
    end

    def self.deny(reason : String? = nil)
      new(false, reason)
    end

    def authorized?
      @authorized
    end

    def denied?
      !@authorized
    end
  end

  # Policy for complex authorization logic
  abstract class Policy
    abstract def authorize(principal : Principal, context : Micro::Core::Context) : AuthorizationResult
  end

  # Simple policy that checks roles
  class RolePolicy < Policy
    getter required_roles : Array(String)
    getter require_all : Bool

    def initialize(@required_roles : Array(String), @require_all = false)
    end

    def authorize(principal : Principal, context : Micro::Core::Context) : AuthorizationResult
      has_roles = if @require_all
                    principal.has_all_roles?(@required_roles)
                  else
                    principal.has_any_role?(@required_roles)
                  end

      if has_roles
        AuthorizationResult.allow
      else
        AuthorizationResult.deny("Missing required role(s): #{@required_roles.join(", ")}")
      end
    end
  end

  # Simple policy that checks permissions
  class PermissionPolicy < Policy
    getter required_permissions : Array(Permission)
    getter require_all : Bool

    def initialize(@required_permissions : Array(Permission), @require_all = true)
    end

    def authorize(principal : Principal, context : Micro::Core::Context) : AuthorizationResult
      has_perms = if @require_all
                    @required_permissions.all? { |p| principal.has_permission?(p) }
                  else
                    @required_permissions.any? { |p| principal.has_permission?(p) }
                  end

      if has_perms
        AuthorizationResult.allow
      else
        AuthorizationResult.deny("Missing required permission(s)")
      end
    end
  end

  # Composite policy that combines multiple policies
  class CompositePolicy < Policy
    enum Operator
      And
      Or
    end

    getter policies : Array(Policy)
    getter operator : Operator

    def initialize(@policies : Array(Policy), @operator = Operator::And)
    end

    def authorize(principal : Principal, context : Micro::Core::Context) : AuthorizationResult
      results = policies.map(&.authorize(principal, context))

      case @operator
      when Operator::And
        # All must pass
        if results.all?(&.authorized?)
          AuthorizationResult.allow
        else
          reasons = results.select(&.denied?).compact_map(&.reason)
          AuthorizationResult.deny(reasons.join("; "))
        end
      when Operator::Or
        # At least one must pass
        if results.any?(&.authorized?)
          AuthorizationResult.allow
        else
          AuthorizationResult.deny("None of the policies were satisfied")
        end
      else
        AuthorizationResult.deny("Unknown operator")
      end
    end
  end
end
