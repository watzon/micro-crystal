# Method routing macros for micro-crystal framework
# These macros process @[Micro::Method] annotations to generate
# RPC handler methods and routing tables at compile time

require "../core/context"
require "../core/codec"
require "../core/middleware"
require "../core/message_encoder"
require "./error_handling"
require "./middleware_support"
require "json"

module Micro::Macros
  # Module that provides method routing functionality
  # Include this in your service class to enable automatic
  # method routing based on @[Micro::Method] annotations
  module MethodRouting
    include ErrorHandling
    include MiddlewareSupport

    # Information about a registered RPC method
    struct MethodInfo
      getter name : String
      getter path : String        # Internal RPC path (not HTTP)
      getter http_method : String # Default HTTP method for RPC
      getter description : String?
      getter summary : String?
      getter timeout : Int32?
      getter auth_required : Bool
      getter deprecated : Bool
      getter metadata : Hash(String, String)
      getter handler_name : String
      getter param_types : Array(String)
      getter return_type : String
      getter request_example : String?
      getter response_examples : Hash(String, String)?

      def initialize(
        @name : String,
        @path : String,
        @http_method : String = "POST",
        @description : String? = nil,
        @summary : String? = nil,
        @timeout : Int32? = nil,
        @auth_required : Bool = false,
        @deprecated : Bool = false,
        @metadata : Hash(String, String) = {} of String => String,
        @handler_name : String = "",
        @param_types : Array(String) = [] of String,
        @return_type : String = "Nil",
        @request_example : String? = nil,
        @response_examples : Hash(String, String)? = nil,
      )
      end
    end

    # Storage for method routing information
    class_property method_routes = {} of String => MethodInfo

    macro included
      # Add finished hook to process method annotations
      macro finished
        # Collect all methods with @[Micro::Method] annotations
        \{% methods_with_annotations = [] of Nil %}
        \{% for method in @type.methods %}
          \{% if ann = method.annotation(::Micro::Method) %}
            \{% methods_with_annotations << method %}
          \{% end %}
        \{% end %}

        # Generate routing table and handlers
        \{% if methods_with_annotations.size > 0 %}
          # Generate static method routing table
          @@method_routes = {
            \{% for method in methods_with_annotations %}
              \{% ann = method.annotation(::Micro::Method) %}

              # Extract annotation parameters using direct access
              \{% method_name = ann[:name] %}
              \{% description = ann[:description] %}
              \{% summary = ann[:summary] %}
              \{% timeout = ann[:timeout] %}
              \{% auth_required = ann[:auth_required] %}
              \{% deprecated = ann[:deprecated] %}
              \{% metadata = ann[:metadata] %}
              \{% request_example = ann[:request_example] %}
              \{% response_examples = ann[:response_examples] %}

              # Set defaults after parsing all args
              \{% if method_name.nil? %}
                \{% method_name = method.name.stringify %}
              \{% end %}

              # For RPC, we use the method name as the default path
              # The gateway will map this to HTTP routes separately
              \{% method_path = "/" + method_name %}
              \{% http_method = "POST" %}  # Default for RPC
              \{% auth_required = auth_required || false %}
              \{% deprecated = deprecated || false %}

              # Extract parameter types
              \{% param_types = [] of Nil %}
              \{% for arg in method.args %}
                \{% param_types << arg.restriction.stringify %}
              \{% end %}
              \{% if param_types.empty? %}
                \{% param_types = [] of String %}
              \{% end %}

              # Extract return type
              \{% return_type = method.return_type ? method.return_type.stringify : "Nil" %}

              # Add to routing table
              \{{method_path}} => MethodInfo.new(
                name: \{{method_name}},
                path: \{{method_path}},
                http_method: \{{http_method}},
                description: \{{description}},
                summary: \{{summary}},
                timeout: \{{timeout}},
                auth_required: \{{auth_required}},
                deprecated: \{{deprecated}},
                metadata: \{{metadata}} || {} of String => String,
                handler_name: \{{method.name.stringify}},
                param_types: [\{% for type in param_types %}\{{type}},\{% end %}] of String,
                return_type: \{{return_type}},
                request_example: \{{request_example}},
                response_examples: \{{response_examples}}
              ),
            \{% end %}
          } of String => MethodInfo

          # Generate handler method that dispatches to actual methods
          def handle_rpc(context : ::Micro::Core::Context) : Nil
            path = context.request.endpoint

            # Find the method info
            method_info = @@method_routes[path]?
            unless method_info
              context.response.status = 404
              context.response.body = {"error" => "Method not found: #{path}"}
              return
            end

            # Check HTTP method if specified
            if http_method = context.request.headers["X-HTTP-Method"]?
              if http_method.upcase != method_info.http_method
                context.response.status = 405
                context.response.body = {"error" => "Method not allowed"}
                return
              end
            end

            # Apply timeout if specified in method annotation
            if timeout = method_info.timeout
              context.request.headers["X-Timeout"] = timeout.to_s
            end

            # Authentication check placeholder - see docs/TODO.md for implementation plan
            # if method_info.auth_required && !authenticated?(context)
            #   context.response.status = 401
            #   context.response.body = {"error" => "Unauthorized"}
            #   return
            # end

            # Build middleware chain if any middleware is configured
            middleware_chain = if self.class.responds_to?(:build_middleware_chain)
              self.class.build_middleware_chain(method_info.handler_name)
            end

            # Streaming handler support planned - see docs/TODO.md

            # Define the actual handler logic
            handler_proc = ->(ctx : ::Micro::Core::Context) do
              dispatch_to_method(ctx, method_info)
            end

            # Execute with middleware if configured, otherwise execute directly
            if middleware_chain
              middleware_chain.execute(context, &handler_proc)
            else
              handler_proc.call(context)
            end
          end

          # Separate method for dispatching to actual handler methods
          private def dispatch_to_method(context : ::Micro::Core::Context, method_info : MethodInfo) : Nil
            # Dispatch to the actual method
            case method_info.handler_name
            \{% for method in methods_with_annotations %}
              when \{{method.name.stringify}}
                # Handle method with parameters
                \{% if method.args.size > 0 %}
                  # Parse request body based on content type
                  body = context.request.body
                  if body.nil?
                    context.response.status = 400
                    context.response.body = {"error" => "Request body required"}
                    return
                  end

                  # Convert to Bytes if needed
                  body_bytes = case body
                  when Bytes
                    body
                  when JSON::Any
                    ::Micro::Core::MessageEncoder.to_bytes(body)
                  else
                    context.response.status = 400
                    context.response.body = {"error" => "Invalid request body type"}
                    return
                  end

                  if body_bytes.empty?
                    context.response.status = 400
                    context.response.body = {"error" => "Request body required"}
                    return
                  end

                  begin
                    # Get codec based on content type
                    content_type = context.request.content_type
                    codec = ::Micro::Core::CodecRegistry.get(content_type)
                    unless codec
                      context.response.status = 415
                      context.response.body = {"error" => "Unsupported content type: #{content_type}"}
                      return
                    end

                    \{% if method.args.size == 0 %}
                      # No parameters, just call the method
                      result = \{{method.name.id}}
                    \{% elsif method.args.size == 1 %}
                      \{% arg = method.args[0] %}
                      # Single parameter - try direct unmarshal first
                      param = ::Micro::Core::MessageEncoder.unmarshal?(body_bytes, \{{arg.restriction}}, codec)

                      # If that failed and body looks like an object, try extracting by arg name
                      if param.nil?
                        json_data = ::Micro::Core::MessageEncoder.unmarshal?(body_bytes, JSON::Any, codec)
                        if json_data && json_data.as_h?
                          begin
                            \{% if arg.restriction.stringify == "String" %}
                              param = json_data[\{{arg.name.stringify}}].as_s
                            \{% elsif arg.restriction.stringify == "Int32" %}
                              param = json_data[\{{arg.name.stringify}}].as_i
                            \{% elsif arg.restriction.stringify == "Int64" %}
                              param = json_data[\{{arg.name.stringify}}].as_i64
                            \{% elsif arg.restriction.stringify == "Float32" %}
                              param = json_data[\{{arg.name.stringify}}].as_f32
                            \{% elsif arg.restriction.stringify == "Float64" %}
                              param = json_data[\{{arg.name.stringify}}].as_f
                            \{% elsif arg.restriction.stringify == "Bool" %}
                              param = json_data[\{{arg.name.stringify}}].as_bool
                            \{% else %}
                              param = \{{arg.restriction}}.from_json(json_data[\{{arg.name.stringify}}].to_json)
                            \{% end %}
                          rescue
                            param = nil
                          end
                        end
                      end

                      if param.nil?
                        context.response.status = 400
                        context.response.body = {"error" => "Failed to parse request parameter"}
                        return
                      end

                      # Validate if the type responds to validate method
                      \{% if arg.restriction.resolve.has_method?("validate") %}
                        if param.responds_to?(:validate)
                          validation_result = param.validate
                          if validation_result.responds_to?(:valid?) && !validation_result.valid?
                            context.response.status = 422
                            if validation_result.responds_to?(:errors)
                              errors_json = validation_result.errors.map do |err|
                                {
                                  "field" => err.field,
                                  "constraint" => err.constraint,
                                  "message" => err.message
                                }
                              end
                              context.response.body = {"errors" => errors_json}
                            else
                              context.response.body = {"error" => "Validation failed"}
                            end
                            return
                          end
                        end
                      \{% end %}

                      # Call the method
                      result = \{{method.name.id}}(param)
                    \{% else %}
                      # Multiple parameters - expect JSON object with named properties
                      json_data = ::Micro::Core::MessageEncoder.unmarshal(body_bytes, JSON::Any, codec)

                      if json_data.nil?
                        context.response.status = 400
                        context.response.body = {"error" => "Failed to parse request parameters"}
                        return
                      end

                      # Extract parameters from JSON object
                      \{% for arg, index in method.args %}
                        \{% arg_name = arg.name.stringify %}
                        param_\{{index}} = begin
                          if json_data.as_h.has_key?(\{{arg_name}})
                            # Convert JSON::Any to the expected type
                            \{% if arg.restriction.stringify == "String" %}
                              json_data[\{{arg_name}}].as_s
                            \{% elsif arg.restriction.stringify == "Int32" %}
                              json_data[\{{arg_name}}].as_i
                            \{% elsif arg.restriction.stringify == "Int64" %}
                              json_data[\{{arg_name}}].as_i64
                            \{% elsif arg.restriction.stringify == "Float32" %}
                              json_data[\{{arg_name}}].as_f32
                            \{% elsif arg.restriction.stringify == "Float64" %}
                              json_data[\{{arg_name}}].as_f
                            \{% elsif arg.restriction.stringify == "Bool" %}
                              json_data[\{{arg_name}}].as_bool
                            \{% elsif arg.restriction.stringify.starts_with?("Array(") %}
                              # Handle arrays by parsing from JSON
                              \{{arg.restriction}}.from_json(json_data[\{{arg_name}}].to_json)
                            \{% else %}
                              # For complex types, parse from JSON
                              \{{arg.restriction}}.from_json(json_data[\{{arg_name}}].to_json)
                            \{% end %}
                          else
                            raise "Missing required parameter: " + \{{arg_name}}
                          end
                        rescue ex
                          raise "Invalid parameter '" + \{{arg_name}} + "': #{ex.message}"
                        end
                      \{% end %}

                      # Call the method with all parameters
                      result = \{{method.name.id}}(
                        \{% for arg, index in method.args %}
                          param_\{{index}}\{% if index < method.args.size - 1 %},\{% end %}
                        \{% end %}
                      )
                    \{% end %}

                    # Handle the result
                    \{% if method.return_type && method.return_type.stringify != "Nil" %}
                      # Marshal the response
                      response_body = ::Micro::Core::MessageEncoder.marshal(result, codec)
                      context.response.body = response_body
                      context.response.headers["Content-Type"] = codec.content_type
                    \{% else %}
                      # No return value, send empty success response
                      context.response.status = 204
                    \{% end %}
                  rescue ex
                    # Use centralized error handling
                    context.response.status = ::Micro::Macros::ErrorHandling.status_for_error(ex)
                    context.response.body = ::Micro::Macros::ErrorHandling.format_error_response(ex)

                    # Log server errors
                    if context.response.status >= 500
                      Log.error(exception: ex) { "Error in #{method_info.name}: #{ex.message}" }
                    end
                  end
                \{% else %}
                  # No parameters, just call the method
                  begin
                    result = \{{method.name.id}}

                    # Handle the result
                    \{% if method.return_type && method.return_type.stringify != "Nil" %}
                      # Get codec for response
                      codec = ::Micro::Core::CodecRegistry.get(context.request.content_type)
                      unless codec
                        context.response.status = 415
                        context.response.body = {"error" => "Unsupported content type: #{context.request.content_type}"}
                        return
                      end
                      response_body = ::Micro::Core::MessageEncoder.marshal(result, codec)
                      context.response.body = response_body
                      context.response.headers["Content-Type"] = codec.content_type
                    \{% else %}
                      # No return value
                      context.response.status = 204
                    \{% end %}
                  rescue ex
                    # Use centralized error handling
                    context.response.status = ::Micro::Macros::ErrorHandling.status_for_error(ex)
                    context.response.body = ::Micro::Macros::ErrorHandling.format_error_response(ex)

                    # Log server errors
                    if context.response.status >= 500
                      Log.error(exception: ex) { "Error in #{method_info.name}: #{ex.message}" }
                    end
                  end
                \{% end %}
            \{% end %}
            else
              # This shouldn't happen if routing table is correct
              context.response.status = 500
              context.response.body = {"error" => "Internal routing error"}
            end
          end

          # Generate method to get all registered methods
          def self.registered_methods : Hash(String, MethodInfo)
            @@method_routes
          end

          # Helper to list all available RPC methods
          def self.list_methods : Array(NamedTuple(name: String, path: String, http_method: String, description: String?))
            @@method_routes.map do |path, info|
              {
                name: info.name,
                path: info.path,
                http_method: info.http_method,
                description: info.description
              }
            end.to_a
          end
        \{% end %}
      end
    end
  end
end
