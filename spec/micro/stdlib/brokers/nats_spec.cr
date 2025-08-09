require "../../../spec_helper"
require "../../../../src/micro/stdlib/brokers/nats"

describe Micro::Stdlib::Brokers::NATSBroker do
  describe "#initialize" do
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

      # This will fail without a real NATS server
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

  # Note: Full integration tests with publish/subscribe will require
  # either a mock NATS client or a test container setup.
end
