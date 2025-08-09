require "../core/middleware"
require "json"
require "../stdlib/middleware/role_guard"

module Micro::Macros
  # Module that provides middleware support through annotations
  # Include this in your service class to enable @[Micro::Middleware] processing
  module MiddlewareSupport
    # Enhanced middleware configuration with priority and conditions
    class MethodMiddlewareConfig
      property middleware : Array(NamedMiddleware)
      property skip : Array(String)
      property require : Array(String)
      property allow_anonymous : Bool
      property priority : Int32?
      property required_roles : Array(String)?
      property require_all_roles : Bool
      property required_permissions : Array(String)?
      property require_all_permissions : Bool
      property policy_name : String?
      property policy_params : Hash(String, JSON::Any)?

      struct NamedMiddleware
        getter name : String
        getter priority : Int32
        getter options : Hash(String, JSON::Any)?

        def initialize(@name : String, @priority : Int32 = 0, @options : Hash(String, JSON::Any)? = nil)
        end
      end

      def initialize(
        @middleware = [] of NamedMiddleware,
        @skip = [] of String,
        @require = [] of String,
        @allow_anonymous = false,
        @priority : Int32? = nil,
        @required_roles : Array(String)? = nil,
        @require_all_roles = false,
        @required_permissions : Array(String)? = nil,
        @require_all_permissions = true,
        @policy_name : String? = nil,
        @policy_params : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    macro included
      # Storage for middleware configurations
      class_property service_middleware_config : MethodMiddlewareConfig?
      class_property service_priority : Int32 = 0
      @@method_middleware_configs : Hash(String, MethodMiddlewareConfig)?

      def self.method_middleware_configs
        @@method_middleware_configs ||= {} of String => MethodMiddlewareConfig
      end

      # Build middleware chain for a method with advanced features
      def self.build_middleware_chain(method_name : String) : Micro::Core::MiddlewareChain?
        chain = Micro::Core::MiddlewareChain.new

        # Get method config
        method_config = method_middleware_configs[method_name]?

        # Check for @[AllowAnonymous]
        if method_config && method_config.allow_anonymous
          chain.allow_anonymous(true)
        end

        # Add service-level middleware with priorities
        if service_config = @@service_middleware_config
          # Service middleware should run first (higher priority)
          service_config.middleware.each do |mw|
            if middleware = Micro::Core::MiddlewareRegistry.get(mw.name, mw.options)
              # Give service middleware high priority so they run before guards
              chain.use_named(mw.name, middleware, mw.priority + 2000 + @@service_priority)
            else
              Log.warn { "Middleware not found: #{mw.name}" }
            end
          end

          # Add service-level RBAC guards AFTER service middleware
          add_rbac_guards(chain, service_config, 500) # Medium priority for service-level

          # Apply service-level skips
          service_config.skip.each { |name| chain.skip(name) }

          # Apply service-level requires
          service_config.require.each { |name| chain.require(name) }
        end

        # Add method-level middleware with priorities
        if method_config
          # Add method-level RBAC guards (higher priority than service)
          add_rbac_guards(chain, method_config, 1500) # High priority for method-level

          method_config.middleware.each do |mw|
            if middleware = Micro::Core::MiddlewareRegistry.get(mw.name, mw.options)
              # Method middleware has higher base priority than service middleware
              chain.use_named(mw.name, middleware, mw.priority + 1000)
            else
              Log.warn { "Middleware not found: #{mw.name}" }
            end
          end

          # Apply method-level skips
          method_config.skip.each { |name| chain.skip(name) }

          # Apply method-level requires
          method_config.require.each { |name| chain.require(name) }
        end

        # Return nil if no middleware configured
        chain.empty? ? nil : chain
      end

      # Helper to add RBAC guards to the chain
      private def self.add_rbac_guards(chain : Micro::Core::MiddlewareChain, config : MethodMiddlewareConfig, base_priority : Int32)
        # Skip if anonymous access is allowed
        return if config.allow_anonymous

        # Add role guard if roles are required
        if roles = config.required_roles
          unless roles.empty?
            role_guard = ::Micro::Stdlib::Middleware::RoleGuard.new(roles, config.require_all_roles)
            chain.use_named("role_guard", role_guard, base_priority + 10)
          end
        end

        # Add permission guard if permissions are required
        if perms = config.required_permissions
          unless perms.empty?
            perm_guard = ::Micro::Stdlib::Middleware::PermissionGuard.new(perms, config.require_all_permissions)
            chain.use_named("permission_guard", perm_guard, base_priority + 20)
          end
        end

        # Add policy guard if policy is specified
        if policy_name = config.policy_name
          policy_guard = ::Micro::Stdlib::Middleware::PolicyGuard.from_policy_name(
            policy_name,
            config.policy_params
          )
          chain.use_named("policy_guard", policy_guard, base_priority + 30)
        end
      end

      # Add finished hook to process middleware annotations
      macro finished
        # Initialize service configuration
        @@service_middleware_config = begin
          _config = MethodMiddlewareConfig.new

          # Process @[Micro::Middleware] at service level
          \{% if ann = @type.annotation(::Micro::Middleware) %}
            \{% names = ann[:names] || ann[0] %}
            \{% options = ann[:options] %}
            \{% priorities = ann[:priorities] %}

            \{% if names %}
              \{% if names.is_a?(ArrayLiteral) %}
                \{% for name, idx in names %}
                  _config.middleware << MethodMiddlewareConfig::NamedMiddleware.new(
                    name: \{{name.id.stringify}},
                    priority: \{% if priorities && priorities.is_a?(ArrayLiteral) %}\{{priorities[idx] || 0}}\{% elsif priorities %}\{{priorities}}\{% else %}0\{% end %},
                    options: \{% if options && options.is_a?(HashLiteral) && options.has_key?(name.stringify) %}\{{options[name.stringify]}}\{% else %}nil\{% end %}
                  )
                \{% end %}
              \{% else %}
                _config.middleware << MethodMiddlewareConfig::NamedMiddleware.new(
                  name: \{{names.id.stringify}},
                  priority: \{% if priorities %}\{{priorities}}\{% else %}0\{% end %},
                  options: \{% if options && options.is_a?(HashLiteral) && options.has_key?(names.stringify) %}\{{options[names.stringify]}}\{% else %}nil\{% end %}
                )
              \{% end %}
            \{% end %}
          \{% end %}

          # Process @[Micro::SkipMiddleware] at service level
          \{% if ann = @type.annotation(::Micro::SkipMiddleware) %}
            \{% names = ann[:names] || ann[0] %}
            \{% if names %}
              \{% if names.is_a?(ArrayLiteral) %}
                \{% for name in names %}
                  _config.skip << \{{name.id.stringify}}
                \{% end %}
              \{% else %}
                _config.skip << \{{names.id.stringify}}
              \{% end %}
            \{% end %}
          \{% end %}

          # Process @[Micro::RequireMiddleware] at service level
          \{% if ann = @type.annotation(::Micro::RequireMiddleware) %}
            \{% names = ann[:names] || ann[0] %}
            \{% if names %}
              \{% if names.is_a?(ArrayLiteral) %}
                \{% for name in names %}
                  _config.require << \{{name.id.stringify}}
                \{% end %}
              \{% else %}
                _config.require << \{{names.id.stringify}}
              \{% end %}
            \{% end %}
          \{% end %}

          _config
        end

        # Process @[Micro::MiddlewarePriority] at service level
        @@service_priority = \{% if ann = @type.annotation(::Micro::MiddlewarePriority) %}\{{ann[:value] || ann[0]}}\{% else %}0\{% end %}

        # Build the method configs hash all at once
        @@method_middleware_configs = {
        \{% for method in @type.methods %}
          \{%
             has_middleware = method.annotation(::Micro::Middleware)
             has_allow_anonymous = method.annotation(::Micro::AllowAnonymous)
             has_skip = method.annotation(::Micro::SkipMiddleware)
             has_require = method.annotation(::Micro::RequireMiddleware)
             has_priority = method.annotation(::Micro::MiddlewarePriority)
             has_role = method.annotation(::Micro::RequireRole)
             has_permission = method.annotation(::Micro::RequirePermission)
             has_policy = method.annotation(::Micro::RequirePolicy)

             # Only generate config if any annotations exist
             has_any_annotation = has_middleware || has_allow_anonymous || has_skip || has_require || has_priority || has_role || has_permission || has_policy
          %}

          \{% if has_any_annotation %}
            \{{method.name.stringify}} => begin
              _method_config = MethodMiddlewareConfig.new

              # Process @[Micro::Middleware]
              \{% if ann = method.annotation(::Micro::Middleware) %}
                \{% names = ann[:names] || ann[0] %}
                \{% options = ann[:options] %}
                \{% priorities = ann[:priorities] %}

                \{% if names %}
                  \{% if names.is_a?(ArrayLiteral) %}
                    \{% for name, idx in names %}
                      _method_config.middleware << MethodMiddlewareConfig::NamedMiddleware.new(
                        name: \{{name.id.stringify}},
                        priority: \{% if priorities && priorities.is_a?(ArrayLiteral) %}\{{priorities[idx] || 0}}\{% elsif priorities %}\{{priorities}}\{% else %}0\{% end %},
                        options: \{% if options && options.is_a?(HashLiteral) && options.has_key?(name.stringify) %}\{{options[name.stringify]}}\{% else %}nil\{% end %}
                      )
                    \{% end %}
                  \{% else %}
                    _method_config.middleware << MethodMiddlewareConfig::NamedMiddleware.new(
                      name: \{{names.id.stringify}},
                      priority: \{% if priorities %}\{{priorities}}\{% else %}0\{% end %},
                      options: \{% if options && options.is_a?(HashLiteral) && options.has_key?(names.stringify) %}\{{options[names.stringify]}}\{% else %}nil\{% end %}
                    )
                  \{% end %}
                \{% end %}
              \{% end %}

              # Process @[Micro::AllowAnonymous]
              \{% if method.annotation(::Micro::AllowAnonymous) %}
                _method_config.allow_anonymous = true
              \{% end %}

              # Process @[Micro::SkipMiddleware]
              \{% if ann = method.annotation(::Micro::SkipMiddleware) %}
                \{% names = ann[:names] || ann[0] %}
                \{% if names %}
                  \{% if names.is_a?(ArrayLiteral) %}
                    \{% for name in names %}
                      _method_config.skip << \{{name.id.stringify}}
                    \{% end %}
                  \{% else %}
                    _method_config.skip << \{{names.id.stringify}}
                  \{% end %}
                \{% end %}
              \{% end %}

              # Process @[Micro::RequireMiddleware]
              \{% if ann = method.annotation(::Micro::RequireMiddleware) %}
                \{% names = ann[:names] || ann[0] %}
                \{% priority = ann[:priority] %}
                \{% if names %}
                  \{% if names.is_a?(ArrayLiteral) %}
                    \{% for name in names %}
                      _method_config.require << \{{name.id.stringify}}
                    \{% end %}
                  \{% else %}
                    _method_config.require << \{{names.id.stringify}}
                  \{% end %}
                \{% end %}
                \{% if priority %}
                  _method_config.priority = \{{priority}}
                \{% end %}
              \{% end %}

              # Process @[Micro::MiddlewarePriority]
              \{% if ann = method.annotation(::Micro::MiddlewarePriority) %}
                _method_config.priority = \{{ann[:value] || ann[0]}}
              \{% end %}

              # Process @[Micro::RequireRole]
              \{% if ann = method.annotation(::Micro::RequireRole) %}
                \{% roles = ann[:roles] || ann[0] %}
                \{% require_all = ann[:require_all] %}
                \{% if roles %}
                  \{% if roles.is_a?(ArrayLiteral) %}
                    _method_config.required_roles = [\{% for role in roles %}\{{role.id.stringify}},\{% end %}]
                  \{% else %}
                    _method_config.required_roles = [\{{roles.id.stringify}}]
                  \{% end %}
                  \{% if require_all %}
                    _method_config.require_all_roles = \{{require_all}}
                  \{% end %}
                \{% end %}
              \{% end %}

              # Process @[Micro::RequirePermission]
              \{% if ann = method.annotation(::Micro::RequirePermission) %}
                \{% permissions = ann[:permissions] || ann[0] %}
                \{% require_all = ann[:require_all] %}
                \{% if permissions %}
                  \{% if permissions.is_a?(ArrayLiteral) %}
                    _method_config.required_permissions = [\{% for perm in permissions %}\{{perm.id.stringify}},\{% end %}]
                  \{% else %}
                    _method_config.required_permissions = [\{{permissions.id.stringify}}]
                  \{% end %}
                  \{% if require_all %}
                    _method_config.require_all_permissions = \{{require_all}}
                  \{% end %}
                \{% end %}
              \{% end %}

              # Process @[Micro::RequirePolicy]
              \{% if ann = method.annotation(::Micro::RequirePolicy) %}
                \{% policy = ann[:policy] || ann[0] %}
                \{% params = ann[:params] %}
                \{% if policy %}
                  _method_config.policy_name = \{{policy.stringify}}
                  \{% if params %}
                    _method_config.policy_params = \{{params}}
                  \{% end %}
                \{% end %}
              \{% end %}

              _method_config
            end,
          \{% end %}
        \{% end %}
        } of String => MethodMiddlewareConfig

        # Helper to check if a method allows anonymous access
        def self.allows_anonymous?(method_name : String) : Bool
          if config = method_middleware_configs[method_name]?
            config.allow_anonymous
          else
            false
          end
        end

        # Helper to check if a method has middleware
        def self.has_middleware?(method_name : String) : Bool
          has_service = @@service_middleware_config && !@@service_middleware_config.not_nil!.middleware.empty?
          has_method = method_middleware_configs.has_key?(method_name)
          has_service || has_method
        end
      end
    end
  end
end
