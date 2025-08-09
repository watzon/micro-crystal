require "./context"
require "./box"

module Micro::Core
  # Configuration for building middleware chains
  struct MiddlewareConfig
    # Middleware entries with configuration
    struct Entry
      getter name : String
      getter priority : Int32
      getter options : Hash(String, JSON::Any)?

      def initialize(@name : String, @priority : Int32 = 0, @options : Hash(String, JSON::Any)? = nil)
      end
    end

    getter middleware : Array(Entry)
    getter skip : Array(String)
    getter require : Array(String)
    getter allow_anonymous : Bool

    def initialize(
      @middleware = [] of Entry,
      @skip = [] of String,
      @require = [] of String,
      @allow_anonymous = false,
    )
    end

    # Builder methods for fluent configuration
    def add_middleware(name : String, priority : Int32 = 0, options : Hash(String, JSON::Any)? = nil) : self
      @middleware << Entry.new(name, priority, options)
      self
    end

    def skip_middleware(*names : String) : self
      @skip.concat(names.to_a)
      self
    end

    def require_middleware(*names : String) : self
      @require.concat(names.to_a)
      self
    end

    def allow_anonymous! : self
      @allow_anonymous = true
      self
    end
  end

  # Base middleware interface for processing requests
  # Middleware can modify the request/response and control the execution flow
  module Middleware
    # Process the request and optionally continue the chain
    #
    # The middleware can:
    # - Modify the context (request/response/attributes)
    # - Call `next_middleware.call(context)` to continue the chain
    # - Return without calling next to short-circuit the chain
    abstract def call(context : Context, next_middleware : Proc(Context, Nil)?) : Nil

    # Convenience method for creating middleware from blocks
    def self.new(&block : Context, Proc(Context, Nil)? -> Nil) : Middleware
      BlockMiddleware.new(block)
    end
  end

  # Simple block-based middleware for quick middleware creation
  private class BlockMiddleware
    include Middleware

    def initialize(@block : Context, Proc(Context, Nil)? -> Nil)
    end

    def call(context : Context, next_middleware : Proc(Context, Nil)?) : Nil
      @block.call(context, next_middleware)
    end
  end

  # Represents a middleware with metadata
  struct MiddlewareEntry
    getter middleware : Middleware
    getter name : String
    getter priority : Int32
    getter conditional : Bool

    def initialize(@middleware : Middleware, @name : String = "", @priority : Int32 = 0, @conditional : Bool = false)
    end
  end

  # Manages execution of middleware chain with advanced features
  class MiddlewareChain
    @entries : Array(MiddlewareEntry)
    @skip_list : Set(String)
    @require_list : Set(String)
    @allow_anonymous : Bool

    def initialize(entries : Array(MiddlewareEntry) = [] of MiddlewareEntry)
      @entries = entries
      @skip_list = Set(String).new
      @require_list = Set(String).new
      @allow_anonymous = false
    end

    # Legacy initialization for backward compatibility
    def self.new(middlewares : Array(Middleware)) : MiddlewareChain
      entries = middlewares.map { |m| MiddlewareEntry.new(m) }
      new(entries)
    end

    # Add middleware to the chain
    def use(middleware : Middleware, name : String = "", priority : Int32 = 0) : self
      @entries << MiddlewareEntry.new(middleware, name, priority)
      sort_by_priority!
      self
    end

    # Add multiple middleware at once
    def use(*middlewares : Middleware) : self
      middlewares.each { |m| use(m) }
      self
    end

    # Add a named middleware with priority
    def use_named(name : String, middleware : Middleware, priority : Int32 = 0) : self
      @entries << MiddlewareEntry.new(middleware, name, priority)
      sort_by_priority!
      self
    end

    # Set middleware to skip
    def skip(*names : String) : self
      @skip_list.concat(names.to_a)
      self
    end

    # Set middleware to require
    def require(*names : String) : self
      @require_list.concat(names.to_a)
      self
    end

    # Set allow anonymous flag (skips auth middleware)
    def allow_anonymous(value : Bool = true) : self
      @allow_anonymous = value
      self
    end

    # Get the number of middleware in the chain
    def size : Int32
      @entries.size
    end

    # Check if the chain is empty
    def empty? : Bool
      @entries.empty?
    end

    # Clear all middleware from the chain
    def clear : self
      @entries.clear
      @skip_list.clear
      @require_list.clear
      @allow_anonymous = false
      self
    end

    # Execute the chain with a final handler
    def execute(context : Context, &handler : Context -> Nil) : Nil
      # Filter middleware based on conditions
      active_middlewares = filter_middlewares

      # Build the chain from the filtered middleware
      chain = build_chain(active_middlewares, handler)

      # Execute the chain
      chain.call(context)
    end

    # Build a new chain by prepending middleware
    def prepend(middleware : Middleware, name : String = "", priority : Int32 = 1000) : MiddlewareChain
      entry = MiddlewareEntry.new(middleware, name, priority)
      new_chain = MiddlewareChain.new([entry] + @entries)
      new_chain.skip_list = @skip_list.dup
      new_chain.require_list = @require_list.dup
      new_chain.set_allow_anonymous(@allow_anonymous)
      new_chain
    end

    # Build a new chain by appending middleware
    def append(middleware : Middleware, name : String = "", priority : Int32 = -1000) : MiddlewareChain
      entry = MiddlewareEntry.new(middleware, name, priority)
      new_chain = MiddlewareChain.new(@entries + [entry])
      new_chain.skip_list = @skip_list.dup
      new_chain.require_list = @require_list.dup
      new_chain.set_allow_anonymous(@allow_anonymous)
      new_chain
    end

    # Merge two chains
    def +(other : MiddlewareChain) : MiddlewareChain
      new_chain = MiddlewareChain.new(@entries + other.entries)
      new_chain.skip_list = @skip_list + other.skip_list
      new_chain.require_list = @require_list + other.require_list
      new_chain.set_allow_anonymous(@allow_anonymous || other.allow_anonymous?)
      new_chain
    end

    protected def entries
      @entries
    end

    protected def skip_list
      @skip_list
    end

    protected def skip_list=(value : Set(String))
      @skip_list = value
    end

    protected def require_list
      @require_list
    end

    protected def require_list=(value : Set(String))
      @require_list = value
    end

    protected def allow_anonymous?
      @allow_anonymous
    end

    protected def set_allow_anonymous(value : Bool)
      @allow_anonymous = value
    end

    private def sort_by_priority!
      @entries.sort! { |a, b| b.priority <=> a.priority }
    end

    private def filter_middlewares : Array(Middleware)
      filtered = [] of Middleware

      @entries.each do |entry|
        # Skip if in skip list
        next if !entry.name.empty? && @skip_list.includes?(entry.name)

        # Skip auth-related middleware if allow_anonymous is set
        if @allow_anonymous && is_auth_middleware?(entry.name)
          next
        end

        # Add required middleware even if not originally in chain
        # This is handled in build_chain method

        filtered << entry.middleware
      end

      # Check for required middleware that might be missing
      @require_list.each do |required_name|
        unless @entries.any? { |e| e.name == required_name }
          # Try to get from registry
          if middleware = MiddlewareRegistry.get(required_name)
            filtered << middleware
          end
        end
      end

      filtered
    end

    private def is_auth_middleware?(name : String) : Bool
      # Common auth middleware names
      auth_names = ["auth", "authentication", "authorize", "authorization", "jwt", "oauth", "bearer"]
      auth_names.any? { |auth_name| name.downcase.includes?(auth_name) }
    end

    private def build_chain(middlewares : Array(Middleware), final_handler : Context -> Nil) : Proc(Context, Nil)
      # Start with the final handler
      chain = final_handler

      # Wrap each middleware in reverse order
      middlewares.reverse_each do |middleware|
        current_middleware = middleware
        next_handler = chain

        chain = ->(ctx : Context) do
          current_middleware.call(ctx, next_handler)
        end
      end

      chain
    end
  end

  # Global middleware registry for named middleware
  class MiddlewareRegistry
    @@middlewares = {} of String => Middleware
    @@factories = {} of String => Proc(Hash(String, JSON::Any), Middleware)

    # Register a middleware instance
    def self.register(name : String, middleware : Middleware) : Nil
      @@middlewares[name] = middleware
    end

    # Register a middleware factory for parameterized middleware
    def self.register_factory(name : String, &factory : Hash(String, JSON::Any) -> Middleware) : Nil
      @@factories[name] = factory
    end

    # Get middleware by name, optionally with configuration options
    def self.get(name : String, options : Hash(String, JSON::Any)? = nil) : Middleware?
      # If options provided and factory exists, use factory
      if options && (factory = @@factories[name]?)
        factory.call(options)
      else
        @@middlewares[name]?
      end
    end

    # Get middleware by name, raising if not found
    def self.get!(name : String, options : Hash(String, JSON::Any)? = nil) : Middleware
      get(name, options) || raise "Middleware not found: #{name}"
    end

    # Check if middleware is registered
    def self.has?(name : String) : Bool
      @@middlewares.has_key?(name) || @@factories.has_key?(name)
    end

    # Get all registered middleware names
    def self.names : Array(String)
      (@@middlewares.keys + @@factories.keys).uniq.sort!
    end

    # Clear all registered middleware (useful for testing)
    def self.clear : Nil
      @@middlewares.clear
      @@factories.clear
    end

    # Build a middleware chain from names with priorities
    def self.build_chain(
      names : Array(String),
      options : Hash(String, Hash(String, JSON::Any)) = {} of String => Hash(String, JSON::Any),
      priorities : Hash(String, Int32) = {} of String => Int32,
    ) : MiddlewareChain
      chain = MiddlewareChain.new

      names.each do |name|
        middleware_options = options[name]?
        if middleware = get(name, middleware_options)
          priority = priorities[name]? || 0
          chain.use_named(name, middleware, priority)
        else
          raise "Middleware not found: #{name}"
        end
      end

      chain
    end

    # Build a middleware chain with configuration
    def self.build_configured_chain(config : MiddlewareConfig) : MiddlewareChain
      chain = MiddlewareChain.new

      # Add middleware with priorities
      config.middleware.each do |entry|
        if middleware = get(entry.name, entry.options)
          chain.use_named(entry.name, middleware, entry.priority)
        else
          raise "Middleware not found: #{entry.name}"
        end
      end

      # Apply skip list
      config.skip.each { |name| chain.skip(name) }

      # Apply require list
      config.require.each { |name| chain.require(name) }

      # Apply allow anonymous
      chain.allow_anonymous(config.allow_anonymous)

      chain
    end
  end
end
