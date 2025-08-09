require "http/headers"

module Micro
  module Core
    # Broker provides message passing abstractions for pub/sub and queuing.
    # Implementations might include NATS, Kafka, Redis Streams, RabbitMQ, etc.
    module Broker
      # Message represents a message to be published or received
      class Message
        property headers : HTTP::Headers
        property body : Bytes

        def initialize(@body : Bytes, @headers = HTTP::Headers.new)
        end

        # Helper to get body as string
        def body_string : String
          String.new(@body)
        end

        # Helper to set body from string
        def body_string=(str : String)
          @body = str.to_slice
        end
      end

      # Publication options
      class PublishOptions
        property topic : String
        property headers : HTTP::Headers

        def initialize(@topic : String, @headers = HTTP::Headers.new)
        end
      end

      # Subscription options
      class SubscribeOptions
        property queue : String?
        property auto_ack : Bool

        def initialize(@queue : String? = nil, @auto_ack : Bool = true)
        end
      end

      # Handler processes received messages
      alias Handler = Proc(Event, Nil)

      # Event wraps a message with subscription metadata
      class Event
        getter message : Message
        getter topic : String
        property? acked : Bool = false

        def initialize(@message : Message, @topic : String)
        end

        # Acknowledge the message
        def ack
          @acked = true
        end

        # Check if message was acknowledged
        def acked?
          @acked
        end
      end

      # Subscriber manages an active subscription
      abstract class Subscriber
        # The topic this subscriber is listening to
        abstract def topic : String

        # Options used for this subscription
        abstract def options : SubscribeOptions

        # Unsubscribe and clean up resources
        abstract def unsubscribe : Nil
      end

      # Base is the abstract interface for message brokers
      abstract class Base
        # Get the broker implementation name
        abstract def name : String

        # Initialize/connect the broker
        abstract def init : Nil

        # Options used to configure this broker
        abstract def options : Options

        # Return the broker address
        abstract def address : String

        # Connect to the broker
        abstract def connect : Nil

        # Disconnect from the broker
        abstract def disconnect : Nil

        # Publish a message to a topic
        abstract def publish(topic : String, message : Message, options : PublishOptions? = nil) : Nil

        # Subscribe to a topic with a handler
        abstract def subscribe(topic : String, handler : Handler, options : SubscribeOptions? = nil) : Subscriber

        # Get the underlying implementation-specific client
        abstract def client
      end

      # Options for broker configuration
      class Options
        property addresses : Array(String)
        property secure : Bool
        property tls_config : TLSConfig?
        property context : Context?

        def initialize(
          @addresses : Array(String) = [] of String,
          @secure : Bool = false,
          @tls_config : TLSConfig? = nil,
          @context : Context? = nil,
        )
        end
      end

      # TLS configuration
      class TLSConfig
        property cert_file : String?
        property key_file : String?
        property ca_file : String?
        property insecure_skip_verify : Bool

        def initialize(
          @cert_file : String? = nil,
          @key_file : String? = nil,
          @ca_file : String? = nil,
          @insecure_skip_verify : Bool = false,
        )
        end
      end

      # Context for passing metadata through broker operations
      class Context
        property metadata : HTTP::Headers

        def initialize(@metadata = HTTP::Headers.new)
        end
      end

      # Errors
      class Error < Exception
      end

      class ConnectionError < Error
      end

      class PublishError < Error
      end

      class SubscribeError < Error
      end
    end
  end
end
