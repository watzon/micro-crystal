require "nats"
require "../../core/broker"

module Micro
  module Stdlib
    module Brokers
      # NATS broker implementation for pub/sub messaging
      class NATSBroker < Core::Broker::Base
        alias NATSClient = ::NATS::Client

        getter name : String = "nats"
        getter options : Core::Broker::Options

        @client : NATSClient?
        @subscribers : Array(NATSSubscriber) = [] of NATSSubscriber
        @mutex = Mutex.new
        @connected = false
        @connection_callbacks_setup = false

        def initialize(@options : Core::Broker::Options = Core::Broker::Options.new)
          # Set default address if none provided
          if @options.addresses.empty?
            @options.addresses = ["nats://localhost:4222"]
          end
        end

        def init : Nil
          # Already initialized via constructor
        end

        def address : String
          @options.addresses.first? || "nats://localhost:4222"
        end

        def connect : Nil
          @mutex.synchronize do
            return if connected?

            begin
              # Parse all addresses as URIs
              servers = @options.addresses.map { |addr| URI.parse(addr) }

              # Create client with all servers for failover
              @client = NATSClient.new(servers)

              # Set up connection callbacks if not already done
              setup_connection_callbacks unless @connection_callbacks_setup

              @connected = true
            rescue ex : ::NATS::Error
              raise Core::Broker::ConnectionError.new("Failed to connect to NATS: #{ex.message}")
            rescue ex : URI::Error
              raise Core::Broker::ConnectionError.new("Invalid NATS URL: #{ex.message}")
            rescue ex : Exception
              raise Core::Broker::ConnectionError.new("Unexpected error connecting to NATS: #{ex.message}")
            end
          end
        end

        def disconnect : Nil
          @mutex.synchronize do
            # Unsubscribe all active subscriptions
            @subscribers.each(&.unsubscribe)
            @subscribers.clear

            # Close the client connection
            @client.try(&.close)
            @client = nil
            @connected = false
            @connection_callbacks_setup = false
          end
        end

        def publish(topic : String, message : Core::Broker::Message, options : Core::Broker::PublishOptions? = nil) : Nil
          client = ensure_connected

          # Convert headers to NATS format (Hash(String, String))
          headers = {} of String => String
          message.headers.each do |key, values|
            # NATS only supports single values, so join multiple values
            headers[key] = values.join(", ")
          end

          # Add any additional headers from publish options
          if options
            options.headers.each do |key, values|
              # NATS only supports single values, so join multiple values
              headers[key] = values.join(", ")
            end
          end

          # Publish the message
          client.publish(topic, message.body, headers: headers.empty? ? nil : headers)
        rescue ex : Exception
          raise Core::Broker::PublishError.new("Failed to publish message: #{ex.message}")
        end

        def subscribe(topic : String, handler : Core::Broker::Handler, options : Core::Broker::SubscribeOptions? = nil) : Core::Broker::Subscriber
          client = ensure_connected
          options ||= Core::Broker::SubscribeOptions.new

          # Create NATS subscription
          nats_sub = if queue = options.queue
                       # Queue subscription for load balancing
                       client.subscribe(topic, queue_group: queue) do |msg|
                         handle_message(msg, topic, handler, options)
                       end
                     else
                       # Regular subscription
                       client.subscribe(topic) do |msg|
                         handle_message(msg, topic, handler, options)
                       end
                     end

          # Create and track subscriber
          subscriber = NATSSubscriber.new(nats_sub, topic, options, client)
          @mutex.synchronize { @subscribers << subscriber }
          subscriber
        rescue ex : Exception
          raise Core::Broker::SubscribeError.new("Failed to subscribe: #{ex.message}")
        end

        def client
          @client
        end

        # Allow setting client for testing
        protected def client=(client : NATSClient?)
          @client = client
        end

        # Check if the broker is currently connected to NATS
        def connected? : Bool
          @connected && !@client.nil?
        end

        # Allow setting connected state for testing
        protected def connected=(value : Bool)
          @connected = value
        end

        # Get current subscribers for testing
        protected def subscribers
          @subscribers
        end

        private def ensure_connected : NATSClient
          connect unless connected?
          @client || raise Micro::Core::TransportError.new(
            "Failed to connect to NATS server",
            Micro::Core::ErrorCode::ConnectionRefused
          )
        end

        private def setup_connection_callbacks
          return unless client = @client

          # Set up error handling
          client.on_error do |error|
            # Log error but don't crash the broker
            # In production, this would use proper logging
            STDERR.puts "NATS error: #{error.message}"
          end

          # Set up disconnect handling
          client.on_disconnect do
            @mutex.synchronize do
              @connected = false
              # Log disconnect
              STDERR.puts "NATS broker disconnected from server"
            end
          end

          # Set up reconnect handling
          client.on_reconnect do
            @mutex.synchronize do
              @connected = true
              # Log reconnection
              STDERR.puts "NATS broker reconnected to server"

              # Resubscribe all active subscriptions
              # The NATS client handles this automatically
            end
          end

          @connection_callbacks_setup = true
        end

        private def handle_message(msg : ::NATS::Message, topic : String, handler : Core::Broker::Handler, options : Core::Broker::SubscribeOptions)
          # Convert NATS message to broker message
          broker_msg = Core::Broker::Message.new(msg.data)

          # Copy headers if present
          if headers = msg.headers
            headers.each do |key, value|
              broker_msg.headers[key] = value
            end
          end

          # Create event
          event = Core::Broker::Event.new(broker_msg, topic)

          # Call handler
          handler.call(event)

          # Auto-ack if enabled (NATS core doesn't require explicit ack)
          event.ack if options.auto_ack
        rescue ex : Exception
          # Log error but don't crash the subscription
          # In production, this would use proper logging
          STDERR.puts "Error handling message: #{ex.message}"
        end

        # Internal subscriber implementation
        private class NATSSubscriber < Core::Broker::Subscriber
          getter topic : String
          getter options : Core::Broker::SubscribeOptions

          def initialize(@nats_sub : ::NATS::Subscription, @topic : String, @options : Core::Broker::SubscribeOptions, @client : NATSClient)
          end

          def unsubscribe : Nil
            @client.unsubscribe(@nats_sub)
          end
        end
      end
    end
  end
end
