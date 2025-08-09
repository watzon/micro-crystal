require "../../core/broker"
require "../../core/closable_resource"
require "../../core/fiber_tracker"

module Micro
  module Stdlib
    module Brokers
      # In-memory broker for testing and development
      class MemoryBroker < Core::Broker::Base
        include Core::FiberTracker

        getter name : String = "memory"
        getter options : Core::Broker::Options

        @subscriptions = Hash(String, Array(SubscriptionEntry)).new { |h, k| h[k] = [] of SubscriptionEntry }
        @mutex = Mutex.new
        @connected = false
        @subscription_counter = 0

        def initialize(@options : Core::Broker::Options = Core::Broker::Options.new)
        end

        def init : Nil
          # Nothing to initialize for in-memory broker
        end

        def address : String
          "memory://localhost"
        end

        def connect : Nil
          @mutex.synchronize do
            @connected = true
          end
        end

        def disconnect : Nil
          @mutex.synchronize do
            @connected = false
            @subscriptions.clear
          end
        end

        def connected? : Bool
          @mutex.synchronize { @connected }
        end

        def client
          nil # In-memory broker doesn't have an underlying client
        end

        def publish(topic : String, message : Core::Broker::Message, options : Core::Broker::PublishOptions? = nil) : Nil
          raise Core::Broker::ConnectionError.new("Not connected") unless connected?

          # Get all matching subscriptions
          subscribers = @mutex.synchronize do
            matching_subs = [] of SubscriptionEntry
            @subscriptions.each do |sub_topic, subs|
              if matches_topic?(sub_topic, topic)
                matching_subs.concat(subs)
              end
            end
            matching_subs
          end

          # Group subscribers by queue
          queued = Hash(String, Array(SubscriptionEntry)).new { |h, k| h[k] = [] of SubscriptionEntry }
          direct = [] of SubscriptionEntry

          subscribers.each do |sub|
            if queue = sub.options.queue
              queued[queue] << sub
            else
              direct << sub
            end
          end

          # Create event from message
          event = Core::Broker::Event.new(message, topic)

          # Deliver to direct subscribers (all get the message)
          direct.each do |sub|
            track_fiber("memory-broker-direct-#{topic}-#{sub.id}") do
              begin
                sub.handler.call(event)
              rescue ex
                # Log error but don't fail the publish
              end
            end
          end

          # Deliver to queued subscribers (one per queue group)
          queued.each do |queue, subs|
            # Randomly select one subscriber from the queue group
            if sub = subs.sample
              track_fiber("memory-broker-queue-#{queue}-#{sub.id}") do
                begin
                  sub.handler.call(event)
                rescue ex
                  # Log error but don't fail the publish
                end
              end
            end
          end
        end

        def subscribe(topic : String, handler : Core::Broker::Handler, options : Core::Broker::SubscribeOptions? = nil) : Core::Broker::Subscriber
          raise Core::Broker::ConnectionError.new("Not connected") unless connected?

          options ||= Core::Broker::SubscribeOptions.new

          entry = @mutex.synchronize do
            @subscription_counter += 1
            new_entry = SubscriptionEntry.new(
              id: @subscription_counter,
              topic: topic,
              options: options,
              handler: handler
            )
            @subscriptions[topic] << new_entry
            new_entry
          end

          MemorySubscriber.new(self, entry)
        end

        def unsubscribe_internal(entry : SubscriptionEntry) : Nil
          @mutex.synchronize do
            @subscriptions[entry.topic].delete(entry)
          end
        end

        private struct SubscriptionEntry
          getter id : Int32
          getter topic : String
          getter options : Core::Broker::SubscribeOptions
          getter handler : Core::Broker::Handler

          def initialize(@id : Int32, @topic : String, @options : Core::Broker::SubscribeOptions, @handler : Core::Broker::Handler)
          end
        end

        private class MemorySubscriber < Core::Broker::Subscriber
          getter topic : String
          getter options : Core::Broker::SubscribeOptions

          def initialize(@broker : MemoryBroker, @entry : SubscriptionEntry)
            @topic = @entry.topic
            @options = @entry.options
            @active = true
          end

          def unsubscribe : Nil
            return unless @active
            @active = false
            @broker.unsubscribe_internal(@entry)
          end

          private property active : Bool
        end

        # Simple topic matching with wildcard support
        private def matches_topic?(pattern : String, topic : String) : Bool
          # Exact match
          return true if pattern == topic

          # Convert pattern to regex
          # * matches exactly one segment
          # ** matches one or more segments
          regex_pattern = pattern
            .gsub(".", "\\.")   # Escape dots
            .gsub("**", ".+")   # ** matches one or more segments
            .gsub("*", "[^.]+") # * matches exactly one segment

          /^#{regex_pattern}$/.matches?(topic)
        end
      end
    end
  end
end
