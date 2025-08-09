require "../../core/registry"
require "../../core/closable_resource"

module Micro
  module Stdlib
    module Registries
      # In-memory implementation of the Registry interface
      # Useful for testing and single-instance deployments
      class MemoryRegistry < Micro::Core::Registry::Base
        @services : Hash(String, Array(Micro::Core::Registry::Service))
        @watchers : Array(MemoryWatcher)
        @mutex : Mutex

        def initialize(options : Micro::Core::Registry::Options)
          @services = {} of String => Array(Micro::Core::Registry::Service)
          @watchers = [] of MemoryWatcher
          @mutex = Mutex.new
        end

        def register(service : Micro::Core::Registry::Service, ttl : Time::Span? = nil) : Nil
          @mutex.synchronize do
            key = service.name
            @services[key] ||= [] of Micro::Core::Registry::Service

            # Remove existing registration for this node if any
            @services[key].reject! do |s|
              s.version == service.version && s.nodes.any? { |n| service.nodes.any? { |sn| sn.id == n.id } }
            end

            # Add the new service
            @services[key] << service

            # Notify watchers
            notify_watchers(Micro::Core::Registry::EventType::Create, service)
          end
        end

        def deregister(service : Micro::Core::Registry::Service) : Nil
          @mutex.synchronize do
            key = service.name
            return unless @services.has_key?(key)

            # Find matching services to remove
            removed_services = @services[key].select do |s|
              s.version == service.version &&
                s.nodes.any? { |n| service.nodes.any? { |sn| sn.id == n.id } }
            end

            # Remove them
            @services[key].reject! do |s|
              removed_services.includes?(s)
            end

            # Clean up empty entries
            @services.delete(key) if @services[key].empty?

            # Notify watchers for each removed service
            removed_services.each do |removed|
              notify_watchers(Micro::Core::Registry::EventType::Delete, removed)
            end
          end
        end

        def get_service(name : String, version : String = "*") : Array(Micro::Core::Registry::Service)
          @mutex.synchronize do
            services = @services[name]? || [] of Micro::Core::Registry::Service

            if version == "*"
              services.dup
            else
              services.select { |s| s.version == version }
            end
          end
        end

        def list_services : Array(Micro::Core::Registry::Service)
          @mutex.synchronize do
            @services.values.flatten
          end
        end

        def watch(service : String? = nil) : Micro::Core::Registry::Watcher
          watcher = MemoryWatcher.new(service)
          @mutex.synchronize do
            @watchers << watcher
          end
          watcher
        end

        private def notify_watchers(event_type : Micro::Core::Registry::EventType, service : Micro::Core::Registry::Service)
          @watchers.each do |watcher|
            next if watcher.stopped?
            next if watcher.service_filter && watcher.service_filter != service.name

            event = Micro::Core::Registry::Event.new(event_type, service)
            watcher.send_event(event)
          end
        end

        # Internal watcher implementation
        private class MemoryWatcher < Micro::Core::Registry::Watcher
          include Micro::Core::ClosableResource

          getter service_filter : String?
          @channel : Channel(Micro::Core::Registry::Event?)

          def initialize(@service_filter : String? = nil)
            @channel = Channel(Micro::Core::Registry::Event?).new(100)
          end

          def stop
            close
          end

          # Implement the perform_close method required by ClosableResource
          protected def perform_close : Nil
            # Send nil to signal stop
            @channel.send(nil) rescue nil

            # Close channel
            @channel.close rescue nil
          end

          def stopped?
            closed?
          end

          def next : Micro::Core::Registry::Event?
            return nil if closed?
            @channel.receive
          rescue Channel::ClosedError
            nil
          end

          def send_event(event : Micro::Core::Registry::Event)
            return if closed?
            @channel.send(event) rescue nil
          end
        end
      end

      # Register the memory registry
      Micro::Core::Registry::Factory.register("memory") do |_|
        opts = Micro::Core::Registry::Options.new
        MemoryRegistry.new(opts)
      end
    end
  end
end
