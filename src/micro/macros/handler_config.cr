# Handler configuration macros for micro-crystal framework
# These macros process @[Micro::Handler] annotations to generate
# handler-specific configuration and behavior at compile time

require "../core/context"

module Micro::Macros
  # Module that provides handler configuration functionality
  # Include this in your service class to enable handler-specific
  # configuration based on @[Micro::Handler] annotations
  module HandlerConfig
    # Information about handler configuration
    struct HandlerConfiguration
      getter streaming : Bool
      getter compress : Bool
      getter max_message_size : Int64?
      getter timeout : Int32?
      getter middlewares : Array(String)
      getter error_handler : String?
      getter codec : String?

      def initialize(
        @streaming : Bool = false,
        @compress : Bool = false,
        @max_message_size : Int64? = nil,
        @timeout : Int32? = nil,
        @middlewares : Array(String) = [] of String,
        @error_handler : String? = nil,
        @codec : String? = nil,
      )
      end
    end

    # Storage for handler configurations
    class_property handler_configs = {} of String => HandlerConfiguration

    macro included
      # Add finished hook to process handler annotations
      macro finished
        # Collect all methods with @[Micro::Handler] annotations
        \{% handler_methods = [] of Nil %}
        \{% for method in @type.methods %}
          \{% if ann = method.annotation(::Micro::Handler) %}
            \{% handler_methods << method %}
          \{% end %}
        \{% end %}

        # Generate handler configuration table
        \{% if handler_methods.size > 0 %}
          # Generate static handler configuration table
          @@handler_configs = {
            \{% for method in handler_methods %}
              \{% ann = method.annotation(::Micro::Handler) %}

              # Extract handler configuration
              \{% streaming = ann[:streaming] || false %}
              \{% compress = ann[:compress] || false %}
              \{% max_message_size = ann[:max_message_size] %}
              \{% timeout = ann[:timeout] %}
              \{% middlewares = ann[:middlewares] || [] of String %}
              \{% error_handler = ann[:error_handler] %}
              \{% codec = ann[:codec] %}

              # Add to configuration table
              \{{method.name.stringify}} => HandlerConfiguration.new(
                streaming: \{{streaming}},
                compress: \{{compress}},
                max_message_size: \{{max_message_size}},
                timeout: \{{timeout}},
                middlewares: \{% if middlewares && middlewares.size > 0 %}\{{middlewares}}.map(&.to_s)\{% else %}[] of String\{% end %},
                error_handler: \{{error_handler}},
                codec: \{{codec}}
              ),
            \{% end %}
          } of String => HandlerConfiguration

          # Generate method to get handler configuration
          def self.handler_config(method_name : String) : HandlerConfiguration?
            @@handler_configs[method_name]?
          end

          # Generate method to check if handler is streaming
          def self.is_streaming_handler?(method_name : String) : Bool
            config = @@handler_configs[method_name]?
            config ? config.streaming : false
          end

          # Helper to list all configured handlers
          def self.configured_handlers : Array(NamedTuple(name: String, streaming: Bool, compress: Bool))
            @@handler_configs.map do |name, config|
              {
                name: name,
                streaming: config.streaming,
                compress: config.compress
              }
            end.to_a
          end
        \{% else %}
          # No handlers with @[Micro::Handler] annotation
          # Generate empty config method so code checking for it doesn't fail
          def self.handler_config(method_name : String) : HandlerConfiguration?
            nil
          end
        \{% end %}
      end
    end
  end
end
