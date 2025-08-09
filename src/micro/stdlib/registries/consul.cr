require "../../core/registry"
require "../../core/closable_resource"
require "../../core/fiber_tracker"
require "http/client"
require "json"
require "uri"

module Micro
  module Stdlib
    module Registries
      # Consul implementation of the Registry interface
      # Provides service discovery and registration via HashiCorp Consul
      class ConsulRegistry < Micro::Core::Registry::Base
        DEFAULT_ADDRESS = "127.0.0.1:8500"
        DEFAULT_SCHEME  = "http"
        DEFAULT_DC      = ""
        DEFAULT_TOKEN   = ""

        @address : String
        @scheme : String
        @datacenter : String
        @token : String
        @client : HTTP::Client
        @watchers : Array(ConsulWatcher)
        @mutex : Mutex

        def initialize(options : Micro::Core::Registry::Options)
          address = options.addresses.first? || DEFAULT_ADDRESS
          @scheme = DEFAULT_SCHEME
          @datacenter = DEFAULT_DC
          @token = DEFAULT_TOKEN

          # Parse address
          uri = URI.parse("#{@scheme}://#{address}")
          @address = "#{uri.host}:#{uri.port || 8500}"

          # Create HTTP client
          host = uri.host || raise ArgumentError.new("Consul address must include host")
          @client = HTTP::Client.new(host, uri.port || 8500, tls: @scheme == "https")
          @client.read_timeout = 30.seconds
          @client.connect_timeout = 10.seconds

          @watchers = [] of ConsulWatcher
          @mutex = Mutex.new
        end

        def register(service : Micro::Core::Registry::Service, ttl : Time::Span? = nil) : Nil
          service.nodes.each do |node|
            # Prepare service registration
            body = {
              "ID"      => "#{service.name}-#{node.id}",
              "Name"    => service.name,
              "Tags"    => build_tags(service),
              "Address" => node.address,
              "Port"    => node.port,
              "Meta"    => merge_metadata(service, node),
              "Check"   => build_check(node, ttl),
            }.to_json

            # Register with Consul
            response = consul_request("PUT", "/v1/agent/service/register", body: body)

            unless response.success?
              raise Micro::Core::Registry::RegistrationError.new(
                "Failed to register service: #{response.status_code} - #{response.body}"
              )
            end
          end
        end

        def deregister(service : Micro::Core::Registry::Service) : Nil
          service.nodes.each do |node|
            service_id = "#{service.name}-#{node.id}"

            # Deregister from Consul
            response = consul_request("PUT", "/v1/agent/service/deregister/#{service_id}")

            unless response.success?
              raise Micro::Core::Registry::RegistrationError.new(
                "Failed to deregister service: #{response.status_code} - #{response.body}"
              )
            end
          end
        end

        def get_service(name : String, version : String = "*") : Array(Micro::Core::Registry::Service)
          # Query Consul for healthy service instances
          response = consul_request("GET", "/v1/health/service/#{name}",
            query: {"passing" => "true", "dc" => @datacenter}.compact)

          unless response.success?
            if response.status_code == 404
              return [] of Micro::Core::Registry::Service
            end
            raise Micro::Core::Registry::ConnectionError.new(
              "Failed to get service: #{response.status_code} - #{response.body}"
            )
          end

          # Parse response
          entries = Array(JSON::Any).from_json(response.body)

          # Group by version
          services_by_version = {} of String => Micro::Core::Registry::Service

          entries.each do |entry|
            service_data = entry["Service"]
            node_data = entry["Node"]

            # Extract version from tags
            tags = service_data["Tags"].as_a.map(&.as_s)
            service_version = extract_version(tags)

            # Skip if version doesn't match
            next if version != "*" && version != service_version

            # Get or create service
            key = "#{name}-#{service_version}"
            service = services_by_version[key]?

            unless service
              metadata = extract_metadata(service_data["Meta"]?)
              service = Micro::Core::Registry::Service.new(
                name: name,
                version: service_version,
                metadata: metadata
              )
              services_by_version[key] = service
            end

            # Add node
            node = Micro::Core::Registry::Node.new(
              id: service_data["ID"].as_s.split("-").last,
              address: service_data["Address"].as_s,
              port: service_data["Port"].as_i,
              metadata: extract_metadata(service_data["Meta"]?)
            )

            service.nodes << node
          end

          services_by_version.values
        end

        def list_services : Array(Micro::Core::Registry::Service)
          # Get all services from Consul
          response = consul_request("GET", "/v1/catalog/services",
            query: {"dc" => @datacenter}.compact)

          unless response.success?
            raise Micro::Core::Registry::ConnectionError.new(
              "Failed to list services: #{response.status_code} - #{response.body}"
            )
          end

          # Parse service names
          services_map = Hash(String, Array(String)).from_json(response.body)

          # Get details for each service
          all_services = [] of Micro::Core::Registry::Service

          services_map.each_key do |service_name|
            all_services.concat(get_service(service_name))
          end

          all_services
        end

        def watch(service : String? = nil) : Micro::Core::Registry::Watcher
          watcher = ConsulWatcher.new(self, service)
          @mutex.synchronize do
            @watchers << watcher
          end
          watcher
        end

        # Internal helper methods
        private def consul_request(method : String, path : String, body : String? = nil, query : Hash(String, String)? = nil)
          headers = HTTP::Headers.new
          headers["Content-Type"] = "application/json"
          headers["X-Consul-Token"] = @token unless @token.empty?

          # Build query string
          query_string = ""
          if query && !query.empty?
            params = query.map { |k, v| "#{k}=#{URI.encode_path_segment(v)}" unless v.empty? }.compact
            query_string = "?#{params.join("&")}" unless params.empty?
          end

          full_path = "#{path}#{query_string}"

          case method
          when "GET"
            @client.get(full_path, headers: headers)
          when "PUT"
            @client.put(full_path, headers: headers, body: body)
          when "DELETE"
            @client.delete(full_path, headers: headers)
          else
            raise ArgumentError.new("Unsupported HTTP method: #{method}")
          end
        rescue ex : Socket::ConnectError | IO::Error
          raise Micro::Core::Registry::ConnectionError.new("Failed to connect to Consul: #{ex.message}")
        end

        private def build_tags(service : Micro::Core::Registry::Service) : Array(String)
          tags = ["version=#{service.version}"]

          # Add metadata as tags with micro- prefix
          service.metadata.each do |key, value|
            tags << "micro-#{key}=#{value}"
          end

          tags
        end

        private def merge_metadata(service : Micro::Core::Registry::Service, node : Micro::Core::Registry::Node) : Hash(String, String)
          # Merge service and node metadata
          metadata = {} of String => String
          service.metadata.each { |k, v| metadata[k] = v }
          node.metadata.each { |k, v| metadata[k] = v }
          metadata
        end

        private def build_check(node : Micro::Core::Registry::Node, ttl : Time::Span?) : Hash(String, JSON::Any::Type)?
          if ttl
            # TTL-based health check
            {
              "TTL"                            => "#{ttl.total_seconds.to_i}s",
              "DeregisterCriticalServiceAfter" => "#{(ttl.total_seconds * 3).to_i}s",
            } of String => JSON::Any::Type
          else
            # HTTP-based health check
            health_endpoint = node.metadata["health_endpoint"]? || "/health"
            {
              "HTTP"                           => "http://#{node.address}:#{node.port}#{health_endpoint}",
              "Interval"                       => "10s",
              "Timeout"                        => "5s",
              "DeregisterCriticalServiceAfter" => "30s",
            } of String => JSON::Any::Type
          end
        end

        protected def extract_version(tags : Array(String)) : String
          tags.each do |tag|
            if tag.starts_with?("version=")
              return tag.split("=", 2)[1]
            end
          end
          "*"
        end

        protected def extract_metadata(meta : JSON::Any?) : Hash(String, String)
          metadata = {} of String => String

          if meta && meta.as_h?
            meta.as_h.each do |key, value|
              metadata[key] = value.to_s
            end
          end

          metadata
        end

        # Internal method for watchers to use
        protected def health_service(name : String, index : Int64) : Tuple(Array(JSON::Any), Int64)
          response = consul_request("GET", "/v1/health/service/#{name}",
            query: {
              "passing" => "true",
              "dc"      => @datacenter,
              "index"   => index.to_s,
              "wait"    => "5m",
            }.compact)

          unless response.success?
            raise Micro::Core::Registry::ConnectionError.new(
              "Failed to watch service: #{response.status_code} - #{response.body}"
            )
          end

          # Extract index from headers
          new_index = response.headers["X-Consul-Index"]?.try(&.to_i64) || index

          entries = Array(JSON::Any).from_json(response.body)
          {entries, new_index}
        end

        # Consul watcher implementation
        private class ConsulWatcher < Micro::Core::Registry::Watcher
          include Micro::Core::ClosableResource
          include Micro::Core::FiberTracker

          @registry : ConsulRegistry
          @service_filter : String?
          @channel : Channel(Micro::Core::Registry::Event?)
          @fiber : Fiber?
          @last_state : Hash(String, Set(String))

          def initialize(@registry : ConsulRegistry, @service_filter : String? = nil)
            @channel = Channel(Micro::Core::Registry::Event?).new(100)
            @last_state = {} of String => Set(String)

            # Start watching in a fiber
            @fiber = track_fiber("consul-watcher-#{object_id}") do
              watch_loop
            end
          end

          def stop
            close
          end

          # Implement the perform_close method required by ClosableResource
          protected def perform_close : Nil
            # Send nil to signal stop
            @channel.send(nil) rescue nil

            # Shutdown watcher fiber
            shutdown_fibers(5.seconds)

            # Close channel
            @channel.close rescue nil
          end

          def next : Micro::Core::Registry::Event?
            return nil if closed?
            @channel.receive
          rescue Channel::ClosedError
            nil
          end

          private def watch_loop
            index = 0_i64

            until closed?
              begin
                if service = @service_filter
                  # Watch specific service
                  entries, new_index = @registry.health_service(service, index)
                  index = new_index

                  process_service_changes(service, entries)
                else
                  # Watch all services - poll periodically
                  services = @registry.list_services
                  process_all_services_changes(services)

                  # Sleep for a bit before next poll
                  sleep 5.seconds
                end
              rescue ex
                # Log error and retry after delay
                sleep 10.seconds unless closed?
              end
            end
          end

          private def process_service_changes(service_name : String, entries : Array(JSON::Any))
            current_nodes = Set(String).new

            # Build current state
            entries.each do |entry|
              service_data = entry["Service"]
              node_id = service_data["ID"].as_s
              current_nodes << node_id
            end

            # Get previous state
            previous_nodes = @last_state[service_name]? || Set(String).new

            # Detect changes
            added_nodes = current_nodes - previous_nodes
            removed_nodes = previous_nodes - current_nodes

            # Convert entries to services and emit events
            if !added_nodes.empty? || !removed_nodes.empty?
              services = build_services_from_entries(service_name, entries)

              services.each do |service|
                if !added_nodes.empty?
                  event = Micro::Core::Registry::Event.new(
                    Micro::Core::Registry::EventType::Create,
                    service
                  )
                  @channel.send(event) unless closed?
                end
              end
            end

            # Update state
            @last_state[service_name] = current_nodes
          end

          private def process_all_services_changes(services : Array(Micro::Core::Registry::Service))
            # For now, just emit update events for any changes
            # In a real implementation, we'd track detailed state
            services.each do |service|
              event = Micro::Core::Registry::Event.new(
                Micro::Core::Registry::EventType::Update,
                service
              )
              @channel.send(event) unless closed?
            end
          end

          private def build_services_from_entries(name : String, entries : Array(JSON::Any)) : Array(Micro::Core::Registry::Service)
            services_by_version = {} of String => Micro::Core::Registry::Service

            entries.each do |entry|
              service_data = entry["Service"]

              # Extract version
              tags = service_data["Tags"].as_a.map(&.as_s)
              version = @registry.extract_version(tags)

              # Get or create service
              key = "#{name}-#{version}"
              service = services_by_version[key]?

              unless service
                service = Micro::Core::Registry::Service.new(
                  name: name,
                  version: version,
                  metadata: @registry.extract_metadata(service_data["Meta"]?)
                )
                services_by_version[key] = service
              end

              # Add node
              node = Micro::Core::Registry::Node.new(
                id: service_data["ID"].as_s.split("-").last,
                address: service_data["Address"].as_s,
                port: service_data["Port"].as_i,
                metadata: @registry.extract_metadata(service_data["Meta"]?)
              )

              service.nodes << node
            end

            services_by_version.values
          end
        end
      end

      # Registry factory registration commented out pending implementation
      # of Registry::Options-based factory pattern (see docs/TODO.md)
      # # Register the consul registry
      # Micro::Core::Registry::Factory.register("consul") do |options|
      #   ConsulRegistry.new(options)
      # end
    end
  end
end
