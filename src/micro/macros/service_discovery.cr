# Service discovery module that enables automatic registration of services
# annotated with @[Micro::Service] without requiring inheritance or includes
module Micro
  module Macros
    module ServiceDiscovery
      # A global constant to track all annotated services at compile time
      # This is untyped at runtime but used for macro processing
      ALL_SERVICES = {} of Nil => Nil

      # This macro hook is called after all code is parsed
      # It processes all types that have the @[Micro::Service] annotation
      macro finished
        {% verbatim do %}
          # Iterate through all types in the program
          {% for type in Object.all_subclasses %}
            # Check if this type has the @[Micro::Service] annotation
            {% if ann = type.annotation(Micro::Service) %}
              # Store the type reference for later processing
              {% ALL_SERVICES[type.stringify] = type %}
            {% end %}
          {% end %}

          # Generate the service registry module
          module Micro::ServiceRegistry
            # Returns all services annotated with @[Micro::Service]
            def self.all_services : Array(Micro::Core::Service.class)
              [
                {% for name, klass in ALL_SERVICES %}
                  {{klass}},
                {% end %}
              ] of Micro::Core::Service.class
            end

            # Returns service metadata for all annotated services
            def self.all_metadata : Hash(String, NamedTuple(
              name: String,
              version: String,
              namespace: String?,
              description: String?,
              metadata: Hash(String, String)?
            ))
              {
                {% for name, klass in ALL_SERVICES %}
                  {% ann = klass.annotation(Micro::Service) %}
                  {{name}} => {
                    name: {{ann[:name] || klass.stringify.underscore}},
                    version: {{ann[:version] || "1.0.0"}},
                    namespace: {{ann[:namespace]}},
                    description: {{ann[:description]}},
                    metadata: {{ann[:metadata]}},
                  },
                {% end %}
              }
            end

            # Creates instances of all annotated services
            def self.create_all : Array(Micro::Core::Service)
              services = [] of Micro::Core::Service

              {% for name, klass in ALL_SERVICES %}
                {% ann = klass.annotation(Micro::Service) %}
                # Generate initialization code for each service
                begin
                  # Check if the class has a parameterless constructor
                  {% if klass.methods.find(&.name.== "new").try(&.args.empty?) %}
                    service = {{klass}}.new
                  {% else %}
                    # If not, try to construct with service options
                    options = Micro::Core::Service::Options.new(
                      name: {{ann[:name] || klass.stringify.underscore}},
                      version: {{ann[:version] || "1.0.0"}},
                      metadata: {{ann[:metadata] || {} of String => String}},
                      server_options: Micro::Core::ServerOptions.new
                    )
                    service = {{klass}}.new(options)
                  {% end %}

                  services << service
                rescue ex
                  puts "Failed to create service {{name}}: #{ex.message}"
                end
              {% end %}

              services
            end

            # Get a specific service class by name
            def self.get_service_class(name : String) : Micro::Core::Service.class?
              case name
              {% for name, klass in ALL_SERVICES %}
                {% ann = klass.annotation(Micro::Service) %}
                when {{ann[:name] || klass.stringify.underscore}}
                  {{klass}}
              {% end %}
              else
                nil
              end
            end

            # Check if a service is registered
            def self.has_service?(name : String) : Bool
              case name
              {% for name, klass in ALL_SERVICES %}
                {% ann = klass.annotation(Micro::Service) %}
                when {{ann[:name] || klass.stringify.underscore}}
                  true
              {% end %}
              else
                false
              end
            end
          end
        {% end %}
      end
    end
  end
end

# Include this module at the top level to enable service discovery
include Micro::Macros::ServiceDiscovery
