require "./broker"
require "./codec"
require "http/headers"

module Micro
  module Core
    # PubSub provides a broker-agnostic publish/subscribe interface
    module PubSub
      # Base class for all PubSub implementations
      abstract class Base
        # Initialize the PubSub system
        abstract def init : Nil

        # Connect to the underlying broker
        abstract def connect : Nil

        # Disconnect from the underlying broker
        abstract def disconnect : Nil

        # Check if connected to the broker
        abstract def connected? : Bool

        # Publish an event to a topic
        abstract def publish(topic : String, event : Event) : Nil

        # Subscribe to a topic with a handler
        # Returns a Subscription that can be used to unsubscribe
        abstract def subscribe(topic : String, handler : Handler) : Subscription

        # Subscribe to a topic with queue group for load balancing
        # Multiple subscribers with the same queue name will load balance messages
        abstract def subscribe(topic : String, queue : String, handler : Handler) : Subscription

        # Unsubscribe a specific subscription
        abstract def unsubscribe(subscription : Subscription) : Nil

        # Get the underlying broker (for broker-specific operations)
        abstract def broker : Broker::Base
      end

      # Event represents a message in the pub/sub system
      class Event
        # Headers for metadata
        getter headers : HTTP::Headers

        # The message payload
        getter data : Bytes

        # Timestamp when the event was created
        getter timestamp : Time

        # Optional event ID for tracking
        getter id : String?

        def initialize(@data : Bytes, @headers : HTTP::Headers = HTTP::Headers.new, @id : String? = nil)
          @timestamp = Time.utc
        end

        # Create an event from any serializable object using a codec
        def self.from(payload : T, codec : Codec) forall T
          data = codec.marshal(payload)
          headers = HTTP::Headers{"content-type" => codec.content_type}
          new(data, headers)
        end

        # Decode the event data using a codec
        def to(type : T.class, codec : Codec) : T forall T
          codec.unmarshal(data, type)
        end

        # Get the event data as a string
        def to_s : String
          String.new(data)
        end
      end

      # Handler is a callback for processing events
      alias Handler = Proc(Event, Nil)

      # Subscription represents an active subscription to a topic
      abstract class Subscription
        # The topic this subscription is for
        abstract def topic : String

        # The queue group (if any)
        abstract def queue : String?

        # Check if the subscription is active
        abstract def active? : Bool

        # Unsubscribe (convenience method)
        abstract def unsubscribe : Nil
      end

      # Options for configuring PubSub
      struct Options
        # The broker to use
        property broker : Broker::Base?

        # Codec for default serialization
        property codec : Codec?

        # Whether to auto-connect on init
        property auto_connect : Bool = true

        # Connection retry settings
        property retry_attempts : Int32 = 3
        property retry_delay : Time::Span = 1.second

        def initialize(
          @broker : Broker::Base? = nil,
          @codec : Codec? = nil,
          @auto_connect : Bool = true,
          @retry_attempts : Int32 = 3,
          @retry_delay : Time::Span = 1.second,
        )
        end
      end

      # Errors
      class Error < Exception; end

      class NotConnectedError < Error; end

      class PublishError < Error; end

      class SubscribeError < Error; end
    end
  end
end
