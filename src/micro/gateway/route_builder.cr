require "../core/middleware"

# Route builder for type-safe route construction
module Micro::Gateway
  # Builder for constructing individual routes
  class RouteBuilder
    property service_name : String
    property method : String
    property path : String
    property service_method : String
    property request_type : String?
    property response_type : String?
    property middleware : Array(::Micro::Core::Middleware)
    property cache_config : CacheConfig?
    property transformations : Array(ResponseTransformation)
    property? public : Bool
    property required_roles : Array(String)

    def initialize(
      @service_name : String,
      @method : String,
      @path : String,
      @service_method : String,
    )
      @middleware = [] of ::Micro::Core::Middleware
      @transformations = [] of ResponseTransformation
      @required_roles = [] of String
      @public = false
    end

    # Set request type for type checking
    def request(type : T.class) forall T
      @request_type = T.name
    end

    # Set response type for type checking
    def response(type : T.class) forall T
      @response_type = T.name
    end

    # Add middleware to this route
    def use(middleware : ::Micro::Core::Middleware)
      @middleware << middleware
    end

    # Configure caching
    def cache(ttl : Time::Span)
      @cache_config = CacheConfig.new(ttl: ttl)
    end

    # Add response transformation
    def transform(&block : JSON::Any -> JSON::Any)
      transformation = ResponseTransformation.new(
        type: ResponseTransformation::TransformationType::Custom,
        custom_handler: block
      )
      @transformations << transformation
    end

    # Remove fields from response
    def remove_fields(*fields : String)
      transformation = ResponseTransformation.new(
        type: ResponseTransformation::TransformationType::RemoveFields,
        fields_to_remove: fields.to_a
      )
      @transformations << transformation
    end

    # Mark route as public (no auth required)
    def public!
      @public = true
    end

    # Require specific roles
    def require_roles(*roles : String)
      @required_roles.concat(roles.to_a)
    end

    # Build the final route
    def build : Route
      Route.new(
        method: @method,
        path: @path,
        service_name: @service_name,
        service_method: @service_method,
        request_type: @request_type,
        response_type: @response_type,
        middleware: @middleware,
        cache_config: @cache_config,
        transformations: @transformations,
        public: @public,
        required_roles: @required_roles
      )
    end
  end

  # Builder for aggregate routes that combine multiple service calls
  class AggregateRouteBuilder
    property service_name : String
    property method : String
    property path : String
    property handler : Proc(HTTP::Server::Context, JSON::Any)?
    property response_type : String?

    @gateway : APIGateway?
    @parallel_tasks : Array(ParallelTask)

    def initialize(@service_name : String, @method : String, @path : String)
      @parallel_tasks = [] of ParallelTask
    end

    # Specify return type
    def returns(type : T.class) forall T
      @response_type = T.name
    end

    # Define parallel execution block
    def parallel(&)
      parallel_builder = ParallelBuilder.new(@gateway)
      with parallel_builder yield
      @parallel_tasks = parallel_builder.tasks

      # Build handler that executes parallel tasks
      @handler = ->(context : HTTP::Server::Context) do
        execute_parallel_tasks(context)
      end
    end

    # Direct service call
    def call(service_class : T.class, method : Symbol, params : Hash | NamedTuple) forall T
      service_name = T.name.split("::").last.underscore

      ParallelTask.new(
        service: service_name,
        method: method.to_s,
        params: params.to_h
      )
    end

    private def execute_parallel_tasks(context : HTTP::Server::Context) : JSON::Any
      # Extract path params
      params = extract_params(context.request.path)

      # Execute tasks in parallel
      channel = Channel(Tuple(String, JSON::Any)).new(@parallel_tasks.size)

      @parallel_tasks.each do |task|
        spawn do
          begin
            # Substitute params in task params
            resolved_params = resolve_params(task.params, params)

            # Call service through gateway
            gateway = @gateway || raise InternalError.new("Gateway not configured")
            result = gateway.call(task.service, task.method, JSON::Any.new(resolved_params))
            channel.send({task.name, result})
          rescue ex
            channel.send({task.name, JSON::Any.new({"error" => ex.message})})
          end
        end
      end

      # Collect results
      results = {} of String => JSON::Any
      @parallel_tasks.size.times do
        name, result = channel.receive
        results[name] = result
      end

      JSON::Any.new(results)
    end

    private def extract_params(path : String) : Hash(String, String)
      # Extract path parameters
      # This is simplified - real implementation would use the route's path pattern
      {} of String => String
    end

    private def resolve_params(params : Hash(String, String), path_params : Hash(String, String)) : Hash(String, JSON::Any)
      resolved = {} of String => JSON::Any

      params.each do |key, value|
        # Replace path param references
        if value.starts_with?(":")
          param_name = value[1..]
          if param_value = path_params[param_name]?
            resolved[key] = JSON::Any.new(param_value)
          end
        else
          resolved[key] = JSON::Any.new(value)
        end
      end

      resolved
    end
  end

  # Builder for parallel task execution
  class ParallelBuilder
    getter tasks : Array(ParallelTask)

    def initialize(@gateway : APIGateway?)
      @tasks = [] of ParallelTask
    end

    # Fetch data from a service
    def fetch(call : ParallelTask) : ParallelTask
      @tasks << call
      call
    end

    # Fetch multiple items
    def fetch_many(calls : Array(ParallelTask)) : Array(ParallelTask)
      @tasks.concat(calls)
      calls
    end
  end

  # Represents a task to execute in parallel
  struct ParallelTask
    getter name : String
    getter service : String
    getter method : String
    getter params : Hash(String, String)

    def initialize(@service : String, @method : String, @params : Hash(String, String), @name : String = "")
      @name = "#{@service}.#{@method}" if @name.empty?
    end
  end
end
