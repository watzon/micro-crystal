# Subscription macros for micro-crystal framework
# These macros process @[Micro::Subscribe] annotations to generate
# pub/sub event handlers and subscription registration at compile time

require "../core/pubsub"
require "../core/codec"
require "json"

# Needed for a crystal formatter bug
newline = "\n"

module Micro::Macros
  # Module that provides pub/sub subscription functionality
  # Include this in your service class to enable automatic
  # event handler registration based on @[Micro::Subscribe] annotations
  module SubscriptionMacros
    # Information about a registered subscription handler
    struct SubscriptionInfo
      getter topic : String
      getter queue_group : String?
      getter auto_ack : Bool
      getter max_retries : Int32
      getter retry_backoff : Int32
      getter description : String?
      getter metadata : Hash(String, String)
      getter handler_name : String
      getter event_type : String

      def initialize(
        @topic : String,
        @queue_group : String? = nil,
        @auto_ack : Bool = true,
        @max_retries : Int32 = 3,
        @retry_backoff : Int32 = 5,
        @description : String? = nil,
        @metadata : Hash(String, String) = {} of String => String,
        @handler_name : String = "",
        @event_type : String = "JSON::Any",
      )
      end
    end

    # Storage for subscription information
    class_property subscription_handlers = {} of String => SubscriptionInfo

    macro included
      # Track active subscriptions for this instance
      @active_subscriptions = [] of ::Micro::Core::PubSub::Subscription

      # Add finished hook to process subscription annotations
      macro finished
        # Collect all methods with @[Micro::Subscribe] annotations
        \{% methods_with_subscriptions = [] of Nil %}
        \{% for method in @type.methods %}
          \{% if ann = method.annotation(::Micro::Subscribe) %}
            \{% methods_with_subscriptions << method %}
          \{% end %}
        \{% end %}

        # Generate subscription table and handlers
        \{% if methods_with_subscriptions.size > 0 %}
          # Generate static subscription handler table
          @@subscription_handlers = {
            \{% for method in methods_with_subscriptions %}
              \{% ann = method.annotation(::Micro::Subscribe) %}

              # Extract annotation parameters using direct access
              \{% topic = ann[:topic] %}
              \{% queue_group = ann[:queue_group] %}
              \{% auto_ack = ann[:auto_ack] %}
              \{% max_retries = ann[:max_retries] %}
              \{% retry_backoff = ann[:retry_backoff] %}
              \{% description = ann[:description] %}
              \{% metadata = ann[:metadata] %}

              # Validate required fields
              \{% if topic.nil? %}
                \{% raise "Topic is required for @[Micro::Subscribe] on method #{method.name}" %}
              \{% end %}

              # Set defaults
              \{% auto_ack = auto_ack.nil? ? true : auto_ack %}
              \{% max_retries = max_retries || 3 %}
              \{% retry_backoff = retry_backoff || 5 %}

              # Extract event type from method parameter
              \{% event_type = "JSON::Any" %}
              \{% if method.args.size == 1 %}
                \{% event_type = method.args[0].restriction.stringify %}
              \{% elsif method.args.size > 1 %}
                \{% raise "Subscribe handler #{method.name} must take exactly one parameter (the event)" %}
              \{% end %}

              # Add to subscription table
              \{{topic}} => SubscriptionInfo.new(
                topic: \{{topic}},
                queue_group: \{{queue_group}},
                auto_ack: \{{auto_ack}},
                max_retries: \{{max_retries}},
                retry_backoff: \{{retry_backoff}},
                description: \{{description}},
                metadata: \{{metadata}} || {} of String => String,
                handler_name: \{{method.name.stringify}},
                event_type: \{{event_type}}
              ),
            \{% end %}
          } of String => SubscriptionInfo

          # Generate subscription registration method
          def register_subscriptions : Nil
            return if @active_subscriptions.size > 0  # Already registered

            Log.info { "Registering #{@@subscription_handlers.size} event subscriptions" }

            @@subscription_handlers.each do |topic, info|
              begin
                # Create handler proc that dispatches to the actual method
                handler = ->(event : ::Micro::Core::PubSub::Event) do
                  handle_subscription_event(topic, event)
                end

                # Subscribe with or without queue group
                subscription = if queue_group = info.queue_group
                  subscribe(topic, queue_group, handler)
                else
                  subscribe(topic, handler)
                end

                if subscription
                  @active_subscriptions << subscription
                  Log.info { "Subscribed to topic '#{topic}'#{queue_group ? " with queue group '#{queue_group}'" : ""}" }
                else
                  Log.warn { "Failed to subscribe to topic '#{topic}'" }
                end
              rescue ex
                Log.error { "Error subscribing to topic '#{topic}': #{ex.message}" }
                raise ex
              end
            end
          end

          # Generate unsubscription method
          def unregister_subscriptions : Nil
            Log.info { "Unregistering #{@active_subscriptions.size} event subscriptions" }

            @active_subscriptions.each do |subscription|
              begin
                subscription.unsubscribe
              rescue ex
                Log.warn { "Error unsubscribing from topic '#{subscription.topic}': #{ex.message}" }
              end
            end
            @active_subscriptions.clear
          end

          # Generate event handler dispatcher
          private def handle_subscription_event(topic : String, event : ::Micro::Core::PubSub::Event) : Nil
            info = @@subscription_handlers[topic]?
            unless info
              Log.warn { "Received event for unknown topic: #{topic}" }
              return
            end

            retry_count = 0
            while retry_count <= info.max_retries
              begin
                # Get codec based on event content type
                content_type = event.headers["content-type"]? || "application/json"
                codec = ::Micro::Core::CodecRegistry.get(content_type)
                unless codec
                  Log.error { "No codec found for content type: #{content_type}" }
                  return
                end

                # Dispatch to the actual handler method
                case info.handler_name
                \{% for method in methods_with_subscriptions %}
                  when \{{method.name.stringify}}
                    \{% if method.args.size == 1 %}
                      # Unmarshal event data to the expected type
                      \{% arg = method.args[0] %}
                      event_data = event.to(\{{arg.restriction}}, codec)

                      # Call the handler method
                      \{{method.name.id}}(event_data)
                    \{% else %}
                      # No parameters, just call the method
                      \{{method.name.id}}
                    \{% end %}
                \{% end %}
                else
                  Log.error { "Unknown handler method: #{info.handler_name}" }
                end

                # Auto-acknowledge if configured
                # Acknowledgment support pending broker implementation - see docs/TODO.md

                # If we get here, the handler succeeded
                break

              rescue ex : ::Micro::Core::CodecError
                Log.error { "Failed to decode event for topic '#{topic}': #{ex.message}" }
                # Don't retry codec errors
                break
              rescue ex
                retry_count += 1
                if retry_count <= info.max_retries
                  Log.warn { "Handler for topic '#{topic}' failed (attempt #{retry_count}/#{info.max_retries}): #{ex.message}" }
                  sleep info.retry_backoff.seconds
                else
                  Log.error { "Handler for topic '#{topic}' failed after #{info.max_retries} attempts: #{ex.message}" }
                  Log.error { ex.backtrace.join(newline) }
                  break
                end
              end
            end
          end

          # Generate method to get all registered subscriptions
          def self.registered_subscriptions : Hash(String, SubscriptionInfo)
            @@subscription_handlers
          end

          # Helper to list all subscription handlers
          def self.list_subscriptions : Array(NamedTuple(topic: String, queue_group: String?, handler: String, description: String?))
            @@subscription_handlers.map do |topic, info|
              {
                topic: info.topic,
                queue_group: info.queue_group,
                handler: info.handler_name,
                description: info.description
              }
            end.to_a
          end

        \{% end %}
      end
    end
  end
end
