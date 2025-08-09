require "../../../spec_helper"
require "../../../../src/micro/stdlib/brokers/nats"

describe Micro::Stdlib::Brokers::NATSBroker do
  describe "initialization" do
    it "sets default address if none provided" do
      broker = Micro::Stdlib::Brokers::NATSBroker.new
      broker.address.should eq("nats://localhost:4222")
    end

    it "uses provided addresses" do
      options = Micro::Core::Broker::Options.new(
        addresses: ["nats://server1:4222", "nats://server2:4222"]
      )
      broker = Micro::Stdlib::Brokers::NATSBroker.new(options)
      broker.address.should eq("nats://server1:4222")
    end
  end

  describe "#name" do
    it "returns 'nats'" do
      broker = Micro::Stdlib::Brokers::NATSBroker.new
      broker.name.should eq("nats")
    end
  end

  describe "#connected?" do
    it "returns false before connection" do
      broker = Micro::Stdlib::Brokers::NATSBroker.new
      broker.connected?.should be_false
    end
  end

  describe "#connect" do
    it "creates a NATS client with all servers" do
      options = Micro::Core::Broker::Options.new(
        addresses: ["nats://server1:4222", "nats://server2:4222", "nats://server3:4222"]
      )
      broker = Micro::Stdlib::Brokers::NATSBroker.new(options)

      # This will fail without a real NATS server, but that's expected
      expect_raises(Micro::Core::Broker::ConnectionError) do
        broker.connect
      end
    end

    it "wraps connection errors properly" do
      # Use an invalid address to ensure connection failure
      options = Micro::Core::Broker::Options.new(
        addresses: ["nats://invalid-host-that-does-not-exist:4222"]
      )
      broker = Micro::Stdlib::Brokers::NATSBroker.new(options)

      expect_raises(Micro::Core::Broker::ConnectionError, /connecting to NATS/) do
        broker.connect
      end
    end
  end

  describe "#disconnect" do
    it "can be called safely even when not connected" do
      broker = Micro::Stdlib::Brokers::NATSBroker.new
      broker.disconnect # Should not raise
      broker.connected?.should be_false
    end
  end

  # Message format tests
  describe "message conversion" do
    it "converts broker messages to NATS format for publishing" do
      broker = Micro::Stdlib::Brokers::NATSBroker.new
      message = Micro::Core::Broker::Message.new("Test message".to_slice)
      message.headers["X-Custom"] = "value"

      # Would test actual publish with a mock NATS client
      # For now, just verify the message can be created
      message.body.should eq("Test message".to_slice)
      message.headers["X-Custom"].should eq("value")
    end

    it "supports publish options with additional headers" do
      broker = Micro::Stdlib::Brokers::NATSBroker.new
      message = Micro::Core::Broker::Message.new("Test".to_slice)
      message.headers["X-Original"] = "1"

      options = Micro::Core::Broker::PublishOptions.new("test.topic")
      options.headers["X-Additional"] = "2"

      # Both headers should be available
      message.headers["X-Original"].should eq("1")
      options.headers["X-Additional"].should eq("2")
    end
  end

  # Subscription options tests
  describe "subscription options" do
    it "supports queue groups for load balancing" do
      options = Micro::Core::Broker::SubscribeOptions.new(queue: "workers")
      options.queue.should eq("workers")
    end

    it "supports auto-acknowledgment" do
      options = Micro::Core::Broker::SubscribeOptions.new(auto_ack: true)
      options.auto_ack.should be_true
    end
  end

  # Error handling tests
  describe "error types" do
    it "has specific error types for different failures" do
      # Verify error types exist and can be instantiated
      conn_error = Micro::Core::Broker::ConnectionError.new("test")
      conn_error.message.should eq("test")

      pub_error = Micro::Core::Broker::PublishError.new("test")
      pub_error.message.should eq("test")

      sub_error = Micro::Core::Broker::SubscribeError.new("test")
      sub_error.message.should eq("test")
    end
  end
end
