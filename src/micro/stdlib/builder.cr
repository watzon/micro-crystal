require "../core/service"
require "./service"

module Micro
  module Stdlib
    # Macro for creating type-safe builders
    macro builder(name, &block)
      class {{name.id}}Builder
        {{block.body}}

        # Build method to create the final object
        def build : {{name.id}}
          validate!
          {{name.id}}.new(
            {% for var in @type.instance_vars %}
              {% if var.annotation(Required) %}
                {{var.name}}: (@{{var.name}} || raise ArgumentError.new("Required field '{{var.name}}' not set")),
              {% elsif var.has_default_value? %}
                {{var.name}}: @{{var.name}} || {{var.default_value}},
              {% else %}
                {{var.name}}: @{{var.name}},
              {% end %}
            {% end %}
          )
        end

        # Validate all required fields are set
        # Validates all required fields and runs custom validators.
    # Raises BuilderError if validation fails.
    private def validate!
          errors = [] of String
          {% for var in @type.instance_vars %}
            {% if var.annotation(Required) %}
              errors << "Required field '{{var.name}}' not set" unless @{{var.name}}
            {% end %}
            {% if validator = var.annotation(Validator) %}
              if value = @{{var.name}}
                unless {{validator.value}}.call(value)
                  errors << "Field '{{var.name}}' failed validation"
                end
              end
            {% end %}
          {% end %}

          unless errors.empty?
            raise ArgumentError.new("Builder validation failed: #{errors.join(", ")}")
          end
        end

        # Generate setter methods with fluent interface
        {% for var in @type.instance_vars %}
          def {{var.name}}(value : {{var.type}}) : self
            @{{var.name}} = value
            self
          end

          def {{var.name}}? : {{var.type}}?
            @{{var.name}}
          end
        {% end %}
      end

      # Add builder class method to the target class
      class {{name.id}}
        def self.builder : {{name.id}}Builder
          {{name.id}}Builder.new
        end
      end
    end

    # Annotation to mark required fields
    annotation Required
    end

    # Annotation for field validation
    annotation Validator
    end

    # Base builder class with common functionality
    abstract class BaseBuilder(T)
      # List of validation errors
      @errors = [] of String

      # Add a validation error
      # Adds a validation error for a specific field.
      # Used by subclasses to report validation failures.
      protected def add_error(field : String, message : String)
        @errors << "#{field}: #{message}"
      end

      # Check if builder is valid
      def valid? : Bool
        validate
        @errors.empty?
      end

      # Get validation errors
      def errors : Array(String)
        validate
        @errors.dup
      end

      # Abstract method to perform validation
      abstract def validate : Nil

      # Abstract method to build the object
      abstract def build : T

      # Build or raise with validation errors
      def build! : T
        unless valid?
          raise ArgumentError.new("Builder validation failed: #{@errors.join(", ")}")
        end
        build
      end
    end

    # Example builder implementation for Service
    class ServiceBuilder < BaseBuilder(Micro::Core::Service::Base)
      property name : String?
      property version : String?
      property transport : Core::Transport?
      property codec : Core::Codec?
      property registry : Core::Registry::Base?
      property broker : Core::Broker::Base?
      property client : Core::Client?
      property server : Core::Server?
      property metadata : HTTP::Headers

      def initialize
        @metadata = HTTP::Headers.new
      end

      # Fluent setters
      def name(value : String) : self
        @name = value
        self
      end

      def version(value : String) : self
        @version = value
        self
      end

      def transport(value : Core::Transport) : self
        @transport = value
        self
      end

      def codec(value : Core::Codec) : self
        @codec = value
        self
      end

      def registry(value : Core::Registry::Base) : self
        @registry = value
        self
      end

      def broker(value : Core::Broker::Base) : self
        @broker = value
        self
      end

      def client(value : Core::Client) : self
        @client = value
        self
      end

      def server(value : Core::Server) : self
        @server = value
        self
      end

      def add_metadata(key : String, value : String) : self
        @metadata[key] = value
        self
      end

      # Validation
      def validate : Nil
        @errors.clear
        add_error("name", "is required") unless @name
        add_error("version", "is required") unless @version

        if n = @name
          add_error("name", "must not be empty") if n.empty?
          add_error("name", "must be alphanumeric with hyphens") unless n.matches?(/^[a-zA-Z0-9-]+$/)
        end

        if v = @version
          add_error("version", "must follow semver format") unless v.matches?(/^\d+\.\d+\.\d+/)
        end
      end

      # Build the service with correct Options wiring
      def build : Micro::Core::Service::Base
        name = @name || raise ArgumentError.new("name is required")

        options = Micro::Core::Service::Options.new(
          name: name,
          version: @version || "0.0.0",
          metadata: @metadata,
          transport: @transport,
          codec: @codec,
          registry: @registry,
          broker: @broker,
        )

        Micro::Stdlib::Service.new(options)
      end
    end

    # Registry Node builder
    class NodeBuilder < BaseBuilder(Core::Registry::Node)
      property id : String?
      property address : String?
      property port : Int32?
      property metadata : Hash(String, String)

      def initialize
        @metadata = {} of String => String
        @port = 0
      end

      def id(value : String) : self
        @id = value
        self
      end

      def address(value : String) : self
        @address = value
        self
      end

      def port(value : Int32) : self
        @port = value
        self
      end

      def add_metadata(key : String, value : String) : self
        @metadata[key] = value
        self
      end

      def validate : Nil
        @errors.clear
        add_error("id", "is required") unless @id
        add_error("address", "is required") unless @address

        if p = @port
          # Port 0 is valid (means any available port)
          add_error("port", "must be between 0 and 65535") unless (0..65535).includes?(p)
        end

        if addr = @address
          # Basic IP/hostname validation
          unless addr.matches?(/^([a-zA-Z0-9-]+\.)*[a-zA-Z0-9-]+$/) ||
                 addr.matches?(/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/)
            add_error("address", "must be a valid hostname or IP address")
          end
        end
      end

      def build : Core::Registry::Node
        Core::Registry::Node.new(
          id: @id || UUID.random.to_s,
          address: @address || "localhost",
          port: @port || 0,
          metadata: @metadata
        )
      end
    end

    # Transport Request builder
    class TransportRequestBuilder < BaseBuilder(Core::TransportRequest)
      property service : String?
      property method : String?
      property body : Bytes?
      property content_type : String?
      property headers : HTTP::Headers
      property timeout : Time::Span?

      def initialize
        @headers = HTTP::Headers.new
        @content_type = "application/json"
        @timeout = 30.seconds
      end

      def service(value : String) : self
        @service = value
        self
      end

      def method(value : String) : self
        @method = value
        self
      end

      def body(value : Bytes | String) : self
        @body = value.is_a?(String) ? value.to_slice : value
        self
      end

      def json_body(value) : self
        @body = value.to_json.to_slice
        @content_type = "application/json"
        self
      end

      def content_type(value : String) : self
        @content_type = value
        self
      end

      def add_header(key : String, value : String) : self
        @headers[key] = value
        self
      end

      def timeout(value : Time::Span) : self
        @timeout = value
        self
      end

      def validate : Nil
        @errors.clear
        add_error("service", "is required") unless @service
        add_error("method", "is required") unless @method
        add_error("body", "is required") unless @body

        if t = @timeout
          add_error("timeout", "must be positive") if t.total_seconds <= 0
        end
      end

      def build : Core::TransportRequest
        Core::TransportRequest.new(
          service: @service || raise("service required"),
          method: @method || raise("method required"),
          body: @body || Bytes.empty,
          content_type: @content_type || "application/octet-stream",
          headers: @headers,
          timeout: @timeout || 30.seconds
        )
      end
    end
  end
end
