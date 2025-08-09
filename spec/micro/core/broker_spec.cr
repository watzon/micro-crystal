require "../../spec_helper"
require "../../../src/micro/core/broker"
require "../../../src/micro/stdlib/brokers/memory"

describe Micro::Core::Broker do
  describe "Message" do
    it "initializes with body and headers" do
      body = "test message".to_slice
      headers = HTTP::Headers{"key" => "value"}
      message = Micro::Core::Broker::Message.new(body, headers)

      message.body.should eq body
      message.headers["key"].should eq "value"
    end

    it "provides string helpers" do
      message = Micro::Core::Broker::Message.new("hello".to_slice)
      message.body_string.should eq "hello"

      message.body_string = "goodbye"
      message.body_string.should eq "goodbye"
    end
  end

  describe "Event" do
    it "tracks acknowledgment" do
      message = Micro::Core::Broker::Message.new("test".to_slice)
      event = Micro::Core::Broker::Event.new(message, "test.topic")

      event.acked?.should be_false
      event.ack
      event.acked?.should be_true
    end
  end

  describe "MemoryBroker" do
    it "connects and disconnects" do
      broker = Micro::Stdlib::Brokers::MemoryBroker.new
      broker.connected?.should be_false

      broker.connect
      broker.connected?.should be_true

      broker.disconnect
      broker.connected?.should be_false
    end

    it "publishes and receives messages" do
      broker = Micro::Stdlib::Brokers::MemoryBroker.new
      broker.connect

      received = [] of String
      handler = ->(event : Micro::Core::Broker::Event) do
        received << event.message.body_string
        event.ack
      end

      broker.subscribe("test.topic", handler)

      message = Micro::Core::Broker::Message.new("hello world".to_slice)
      broker.publish("test.topic", message)

      sleep 10.milliseconds
      received.should eq ["hello world"]
    end

    it "supports wildcard subscriptions" do
      broker = Micro::Stdlib::Brokers::MemoryBroker.new
      broker.connect

      received = [] of String
      handler = ->(event : Micro::Core::Broker::Event) do
        received << event.topic
      end

      broker.subscribe("user.*", handler)

      broker.publish("user.signup", Micro::Core::Broker::Message.new("".to_slice))
      broker.publish("user.login", Micro::Core::Broker::Message.new("".to_slice))
      broker.publish("system.alert", Micro::Core::Broker::Message.new("".to_slice))

      sleep 10.milliseconds
      received.should contain("user.signup")
      received.should contain("user.login")
      received.should_not contain("system.alert")
    end

    it "handles unsubscribe" do
      broker = Micro::Stdlib::Brokers::MemoryBroker.new
      broker.connect

      count = 0
      handler = ->(_event : Micro::Core::Broker::Event) do
        count += 1
      end

      subscriber = broker.subscribe("test", handler)

      broker.publish("test", Micro::Core::Broker::Message.new("1".to_slice))
      sleep 10.milliseconds
      count.should eq 1

      subscriber.unsubscribe

      broker.publish("test", Micro::Core::Broker::Message.new("2".to_slice))
      sleep 10.milliseconds
      count.should eq 1 # Should not increase
    end

    it "raises error when not connected" do
      broker = Micro::Stdlib::Brokers::MemoryBroker.new

      expect_raises(Micro::Core::Broker::ConnectionError) do
        broker.publish("test", Micro::Core::Broker::Message.new("".to_slice))
      end

      expect_raises(Micro::Core::Broker::ConnectionError) do
        broker.subscribe("test", ->(_e : Micro::Core::Broker::Event) { })
      end
    end
  end
end
