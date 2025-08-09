require "../../core/pubsub"
require "../../core/broker"
require "../../core/codec"

module Micro
  module Stdlib
    module PubSub
      # Default PubSub implementation that wraps a broker
      class Default < Core::PubSub::Base
        getter broker : Core::Broker::Base
        getter codec : Core::Codec
        getter options : Core::PubSub::Options

        @subscriptions = [] of BrokerSubscription
        @mutex = Mutex.new

        def initialize(@options : Core::PubSub::Options)
          @broker = @options.broker || raise Core::PubSub::Error.new("No broker configured")
          @codec = @options.codec || get_default_codec
        end

        def init : Nil
          @broker.init
          connect if @options.auto_connect
        end

        def connect : Nil
          @broker.connect
        end

        def disconnect : Nil
          @mutex.synchronize do
            # Unsubscribe all active subscriptions
            @subscriptions.each do |sub|
              begin
                sub.unsubscribe
              rescue
                # Ignore errors during disconnect
              end
            end
            @subscriptions.clear
          end

          @broker.disconnect
        end

        def connected? : Bool
          @broker.connected?
        end

        def publish(topic : String, event : Core::PubSub::Event) : Nil
          raise Core::PubSub::NotConnectedError.new("Not connected to broker") unless connected?

          # Convert PubSub::Event to Broker::Message
          message = Core::Broker::Message.new(
            body: event.data,
            headers: event.headers
          )

          begin
            @broker.publish(topic, message)
          rescue ex : Core::Broker::Error
            raise Core::PubSub::PublishError.new("Failed to publish: #{ex.message}")
          end
        end

        def subscribe(topic : String, handler : Core::PubSub::Handler) : Core::PubSub::Subscription
          subscribe(topic, nil, handler)
        end

        def subscribe(topic : String, queue : String?, handler : Core::PubSub::Handler) : Core::PubSub::Subscription
          raise Core::PubSub::NotConnectedError.new("Not connected to broker") unless connected?

          # Create a broker handler that converts broker events to pubsub events
          broker_handler = ->(broker_event : Core::Broker::Event) do
            event = Core::PubSub::Event.new(
              data: broker_event.message.body,
              headers: broker_event.message.headers
            )
            handler.call(event)
          end

          begin
            # Subscribe through the broker
            options = Core::Broker::SubscribeOptions.new(queue: queue)
            broker_sub = @broker.subscribe(topic, broker_handler, options)

            # Wrap in our subscription type
            subscription = BrokerSubscription.new(self, broker_sub, topic, queue)

            @mutex.synchronize do
              @subscriptions << subscription
            end

            subscription
          rescue ex : Core::Broker::Error
            raise Core::PubSub::SubscribeError.new("Failed to subscribe: #{ex.message}")
          end
        end

        def unsubscribe(subscription : Core::PubSub::Subscription) : Nil
          if sub = subscription.as?(BrokerSubscription)
            @mutex.synchronize do
              @subscriptions.delete(sub)
            end
            sub.unsubscribe
          end
        end

        private def get_default_codec : Core::Codec
          # Try to get JSON codec from registry
          if codec = Core::CodecRegistry.instance.get("application/json")
            codec
          else
            raise Core::PubSub::Error.new("No default codec available")
          end
        end

        # Internal subscription wrapper
        private class BrokerSubscription < Core::PubSub::Subscription
          getter topic : String
          getter queue : String?

          def initialize(@pubsub : Default, @broker_sub : Core::Broker::Subscriber, @topic : String, @queue : String?)
          end

          def active? : Bool
            # Since Broker::Subscriber doesn't have an active? method, we track it ourselves
            @active
          end

          def unsubscribe : Nil
            return unless @active
            @active = false
            @broker_sub.unsubscribe
          end

          private property active : Bool = true
        end
      end
    end
  end
end
