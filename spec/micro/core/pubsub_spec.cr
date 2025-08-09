require "../../spec_helper"
require "../../../src/micro/core/pubsub"
require "../../../src/micro/stdlib/pubsub/default"
require "../../../src/micro/stdlib/brokers/memory"
require "../../../src/micro/stdlib/codecs/json"

describe Micro::Core::PubSub do
  describe "Event" do
    it "creates an event with data and headers" do
      data = "Hello, World!".to_slice
      headers = HTTP::Headers{"content-type" => "text/plain"}
      event = Micro::Core::PubSub::Event.new(data, headers)

      event.data.should eq data
      event.headers["content-type"].should eq "text/plain"
      event.timestamp.should be_a Time
      event.id.should be_nil
    end

    it "creates an event from a serializable object" do
      codec = Micro::Stdlib::Codecs::JSON.new
      payload = {name: "Alice", age: 30}

      event = Micro::Core::PubSub::Event.from(payload, codec)

      event.headers["content-type"].should eq "application/json"
      event.to_s.should contain "Alice"
      event.to_s.should contain "30"
    end

    it "decodes event data using a codec" do
      codec = Micro::Stdlib::Codecs::JSON.new
      data = {"message" => "Hello"}.to_json.to_slice
      headers = HTTP::Headers{"content-type" => "application/json"}
      event = Micro::Core::PubSub::Event.new(data, headers)

      result = event.to(Hash(String, String), codec)
      result["message"].should eq "Hello"
    end

    it "converts event data to string" do
      data = "Test message".to_slice
      event = Micro::Core::PubSub::Event.new(data)

      event.to_s.should eq "Test message"
    end
  end

  describe "with MemoryBroker" do
    it "publishes and subscribes to events" do
      broker = Micro::Stdlib::Brokers::MemoryBroker.new
      options = Micro::Core::PubSub::Options.new(broker: broker)
      pubsub = Micro::Stdlib::PubSub::Default.new(options)
      pubsub.init

      received_events = [] of Micro::Core::PubSub::Event

      # Subscribe to a topic
      handler = ->(event : Micro::Core::PubSub::Event) {
        received_events << event
      }
      subscription = pubsub.subscribe("test.topic", handler)

      # Publish an event
      event = Micro::Core::PubSub::Event.new("Hello PubSub".to_slice)
      pubsub.publish("test.topic", event)

      # Allow time for async delivery
      sleep 0.01.seconds

      received_events.size.should eq 1
      received_events.first.to_s.should eq "Hello PubSub"

      # Cleanup
      subscription.unsubscribe
      pubsub.disconnect
    end

    it "supports queue groups for load balancing" do
      broker = Micro::Stdlib::Brokers::MemoryBroker.new
      options = Micro::Core::PubSub::Options.new(broker: broker)
      pubsub = Micro::Stdlib::PubSub::Default.new(options)
      pubsub.init

      group1_count = 0
      group2_count = 0

      # Create two subscribers in the same queue group
      worker1 = ->(_event : Micro::Core::PubSub::Event) {
        group1_count += 1
      }
      sub1 = pubsub.subscribe("work.queue", "workers", worker1)

      worker2 = ->(_event : Micro::Core::PubSub::Event) {
        group2_count += 1
      }
      sub2 = pubsub.subscribe("work.queue", "workers", worker2)

      # Publish multiple events
      10.times do |i|
        event = Micro::Core::PubSub::Event.new("Work #{i}".to_slice)
        pubsub.publish("work.queue", event)
      end

      # Allow time for async delivery
      sleep 0.05.seconds

      # Total should be 10, distributed between the two
      (group1_count + group2_count).should eq 10

      # Both should have received at least one message
      group1_count.should be > 0
      group2_count.should be > 0

      # Cleanup
      sub1.unsubscribe
      sub2.unsubscribe
      pubsub.disconnect
    end

    it "handles multiple topics independently" do
      broker = Micro::Stdlib::Brokers::MemoryBroker.new
      options = Micro::Core::PubSub::Options.new(broker: broker)
      pubsub = Micro::Stdlib::PubSub::Default.new(options)
      pubsub.init

      topic1_events = [] of String
      topic2_events = [] of String

      handler1 = ->(event : Micro::Core::PubSub::Event) {
        topic1_events << event.to_s
      }
      sub1 = pubsub.subscribe("topic.one", handler1)

      handler2 = ->(event : Micro::Core::PubSub::Event) {
        topic2_events << event.to_s
      }
      sub2 = pubsub.subscribe("topic.two", handler2)

      # Publish to different topics
      pubsub.publish("topic.one", Micro::Core::PubSub::Event.new("Message 1".to_slice))
      pubsub.publish("topic.two", Micro::Core::PubSub::Event.new("Message 2".to_slice))
      pubsub.publish("topic.one", Micro::Core::PubSub::Event.new("Message 3".to_slice))

      sleep 0.02.seconds

      topic1_events.should eq ["Message 1", "Message 3"]
      topic2_events.should eq ["Message 2"]

      # Cleanup
      sub1.unsubscribe
      sub2.unsubscribe
      pubsub.disconnect
    end

    it "raises error when not connected" do
      broker = Micro::Stdlib::Brokers::MemoryBroker.new
      options = Micro::Core::PubSub::Options.new(broker: broker, auto_connect: false)
      pubsub = Micro::Stdlib::PubSub::Default.new(options)
      pubsub.init

      event = Micro::Core::PubSub::Event.new("Test".to_slice)

      expect_raises(Micro::Core::PubSub::NotConnectedError) do
        pubsub.publish("test", event)
      end

      expect_raises(Micro::Core::PubSub::NotConnectedError) do
        handler = ->(_e : Micro::Core::PubSub::Event) { }
        pubsub.subscribe("test", handler)
      end
    end

    it "properly cleans up subscriptions on disconnect" do
      broker = Micro::Stdlib::Brokers::MemoryBroker.new
      options = Micro::Core::PubSub::Options.new(broker: broker)
      pubsub = Micro::Stdlib::PubSub::Default.new(options)
      pubsub.init

      received = 0
      handler = ->(_event : Micro::Core::PubSub::Event) {
        received += 1
      }
      sub = pubsub.subscribe("cleanup.test", handler)

      # Verify subscription works
      pubsub.publish("cleanup.test", Micro::Core::PubSub::Event.new("Test".to_slice))
      sleep 0.01.seconds
      received.should eq 1

      # Disconnect and verify subscription is inactive
      pubsub.disconnect
      sub.active?.should be_false

      # Reconnect and verify old subscription doesn't receive messages
      pubsub.connect
      pubsub.publish("cleanup.test", Micro::Core::PubSub::Event.new("Test 2".to_slice))
      sleep 0.01.seconds
      received.should eq 1 # Should still be 1
    end
  end
end
