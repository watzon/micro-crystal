# Advanced service discovery that automatically adds service functionality
# to classes annotated with @[Micro::Service]
module Micro
  module Macros
    module AutoService
      # Track services for auto-registration
      AUTO_SERVICES = {} of Nil => Nil

      # This will be called after all types are defined
      macro finished
        {% verbatim do %}
          # Process all types with @[Micro::Service] annotation
          {% for type in Object.all_subclasses %}
            {% if ann = type.annotation(Micro::Service) %}
              {% AUTO_SERVICES[type.stringify] = type %}

              # Inject service functionality into the annotated class
              class {{type}}
                # Add service metadata as class methods
                def self.service_metadata
                  {
                    name: {{ann[:name] || type.stringify.underscore}},
                    version: {{ann[:version] || "1.0.0"}},
                    namespace: {{ann[:namespace]}},
                    description: {{ann[:description]}},
                    metadata: {{ann[:metadata] || {} of String => String}},
                  }
                end

                # Add instance methods for service behavior
                def service_name : String
                  {{ann[:name] || type.stringify.underscore}}
                end

                def service_version : String
                  {{ann[:version] || "1.0.0"}}
                end

                def service_info : String
                  "#{service_name} v#{service_version}"
                end

                # If the class doesn't already have these methods, add basic implementations
                {% unless type.methods.map(&.name).includes?("register") %}
                  def register
                    puts "[AutoService] Registering #{service_info}"
                    # In a real implementation, this would register with a registry
                    true
                  end
                {% end %}

                {% unless type.methods.map(&.name).includes?("deregister") %}
                  def deregister
                    puts "[AutoService] Deregistering #{service_info}"
                    # In a real implementation, this would deregister from a registry
                    true
                  end
                {% end %}

                {% unless type.methods.map(&.name).includes?("start") %}
                  def start
                    puts "[AutoService] Starting #{service_info}"
                    register
                  end
                {% end %}

                {% unless type.methods.map(&.name).includes?("stop") %}
                  def stop
                    puts "[AutoService] Stopping #{service_info}"
                    deregister
                  end
                {% end %}
              end

              # Process @[Micro::Method] annotations if present
              {% for method in type.methods %}
                {% if method_ann = method.annotation(Micro::Method) %}
                  class {{type}}
                    # Add method metadata
                    {% method_list = type.constant("METHOD_LIST") || [] of Nil %}
                    {% method_list = method_list + [{
                         name:        method_ann[:name] || method.name.stringify,
                         path:        method_ann[:path] || "/" + (method_ann[:name] || method.name.stringify),
                         description: method_ann[:description],
                         method_name: method.name.stringify,
                       }] %}
                    METHOD_LIST = {{method_list}}

                    def self.list_methods
                      METHOD_LIST
                    end
                  end
                {% end %}
              {% end %}
            {% end %}
          {% end %}

          # Create the auto-discovery module
          module Micro::AutoDiscovery
            # Get all auto-discovered services
            def self.services : Array({{AUTO_SERVICES.values.first || Object}}.class)
              [
                {% for name, klass in AUTO_SERVICES %}
                  {{klass}},
                {% end %}
              ] of {{AUTO_SERVICES.values.first || Object}}.class
            end

            # Create and start all services
            def self.start_all
              puts "Starting all auto-discovered services..."

              {% for name, klass in AUTO_SERVICES %}
                begin
                  service = {{klass}}.new
                  service.start
                  puts "  ✓ Started {{klass}}"
                rescue ex
                  puts "  ✗ Failed to start {{klass}}: #{ex.message}"
                end
              {% end %}
            end

            # Display all discovered services and their methods
            def self.catalog
              puts "=== Service Catalog ==="
              {% for name, klass in AUTO_SERVICES %}
                {% ann = klass.annotation(Micro::Service) %}
                puts "\n{{klass}}:"
                puts "  Name: {{ann[:name] || klass.stringify.underscore}}"
                puts "  Version: {{ann[:version] || "1.0.0"}}"
                {% if ann[:description] %}
                  puts "  Description: {{ann[:description]}}"
                {% end %}

                {% if klass.has_constant?("METHOD_LIST") %}
                  puts "  Methods:"
                  {{klass}}.list_methods.each do |method|
                    puts "    • #{method[:name]} (#{method[:path]})"
                    {% if method[:description] %}
                      puts "      #{method[:description]}"
                    {% end %}
                  end
                {% end %}
              {% end %}
            end
          end
        {% end %}
      end
    end
  end
end

# Include at the top level to enable auto service functionality
include Micro::Macros::AutoService
