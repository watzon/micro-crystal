# Client stub generation macros for micro-crystal framework
# These macros generate type-safe client methods for calling RPC services

require "../core/codec"
require "../core/context"
require "../core/transport"
require "json"
require "http/headers"

module Micro::Macros
  # Module that generates client stub methods for RPC calls
  # Include this in a client class to generate methods based on a service interface
  module ClientStubs
    # Generate client stubs for a service interface
    macro generate_client_for(service_class)
      {% service_ann = service_class.resolve.annotation(::Micro::Service) %}
      {% unless service_ann %}
        {% raise "#{service_class} must have @[Micro::Service] annotation" %}
      {% end %}

      # Extract service metadata
      {% service_name = service_ann[:name] %}
      {% service_version = service_ann[:version] || "1.0.0" %}

      # Service metadata
      def service_name : String
        {{service_name}}
      end

      def service_version : String
        {{service_version}}
      end

      # Find all methods with @[Micro::Method] annotation
      {% methods = [] of Nil %}
      {% for method in service_class.resolve.methods %}
        {% if ann = method.annotation(::Micro::Method) %}
          {% methods << method %}
        {% end %}
      {% end %}

      # Generate client stub for each method
      {% for method in methods %}
        {% ann = method.annotation(::Micro::Method) %}
        {% method_name = ann[:name] || method.name.stringify %}
        {% method_path = ann[:path] || "/" + method_name %}
        {% timeout = ann[:timeout] %}

        # Check if this is a streaming method
        {% handler_ann = method.annotation(::Micro::Handler) %}
        {% is_streaming = handler_ann && handler_ann[:streaming] %}

        {% if is_streaming %}
          # Generate streaming method stub
          def {{method.name.id}}({% for arg in method.args %}{{arg.name.id}} : {{arg.restriction}},{% end %}) : ::Micro::Core::Stream
            # Create request based on parameters
            {% if method.args.size == 0 %}
              request_body = Bytes.empty
            {% elsif method.args.size == 1 %}
              # Single parameter - marshal it directly
              codec = codec()
              request_body = codec.marshal({{method.args[0].name.id}})
            {% else %}
              # Multiple parameters - create JSON object
              params = {
                {% for arg in method.args %}
                  {{arg.name.stringify}} => {{arg.name.id}},
                {% end %}
              }
              codec = get_codec()
              request_body = codec.marshal(params)
            {% end %}

            # Create request
            request = ::Micro::Core::Request.new(
              service: service_name,
              endpoint: {{method_path}},
              body: request_body,
              content_type: codec().content_type,
              headers: HTTP::Headers.new
            )

            # Call streaming method
            call_stream(request)
          end
        {% else %}
          # Generate regular RPC method stub
          def {{method.name.id}}({% for arg in method.args %}{{arg.name.id}} : {{arg.restriction}},{% end %}) {% if method.return_type %}: {{method.return_type}}{% end %}
            # Create request based on parameters
            {% if method.args.size == 0 %}
              request_body = Bytes.empty
            {% elsif method.args.size == 1 %}
              # Single parameter - marshal it directly
              codec = codec()
              request_body = codec.marshal({{method.args[0].name.id}})
            {% else %}
              # Multiple parameters - create JSON object
              params = {
                {% for arg in method.args %}
                  {{arg.name.stringify}} => {{arg.name.id}},
                {% end %}
              }
              codec = codec()
              request_body = codec.marshal(params)
            {% end %}

            # Create request
            request = ::Micro::Core::Request.new(
              service: service_name,
              endpoint: {{method_path}},
              body: request_body,
              content_type: codec().content_type,
              headers: HTTP::Headers.new
            )

            # Add timeout if specified
            {% if timeout %}
              request.headers["X-Timeout"] = {{timeout}}.to_s
            {% end %}

            # Call the service
            response = call(request)

            # Handle response
            {% if method.return_type && method.return_type.stringify != "Nil" %}
              # Unmarshal response
              codec = codec()
              body_bytes = case body = response.body
              when Bytes
                body
              when JSON::Any
                body.to_json.to_slice
              when Hash
                codec.marshal(body)
              else
                Bytes.empty
              end
              codec.unmarshal(body_bytes, {{method.return_type}})
            {% else %}
              # Void method, return nil
              nil
            {% end %}
          end
        {% end %}
      {% end %}

      # Generate convenience method to list available RPC methods
      def self.available_methods : Array(NamedTuple(name: String, path: String, streaming: Bool))
        [
          {% for method in methods %}
            {% ann = method.annotation(::Micro::Method) %}
            {% handler_ann = method.annotation(::Micro::Handler) %}
            {
              name: {{ann[:name] || method.name.stringify}},
              path: {{ann[:path] || "/" + (ann[:name] || method.name.stringify)}},
              streaming: {{handler_ann && handler_ann[:streaming] ? true : false}}
            },
          {% end %}
        ]
      end
    end

    # Abstract methods that must be implemented by the including class
    abstract def call(request : ::Micro::Core::Request) : ::Micro::Core::Response
    abstract def call_stream(request : ::Micro::Core::Request) : ::Micro::Core::Stream
    abstract def codec : ::Micro::Core::Codec
  end
end
