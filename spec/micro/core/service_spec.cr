require "../../spec_helper"

# Simple tests for service module without full mocks
describe Micro::Core::Service::Options do
  describe "#initialize" do
    it "creates options with required fields" do
      options = Micro::Core::Service::Options.new(
        name: "test-service",
        version: "1.0.0"
      )

      options.name.should eq("test-service")
      options.version.should eq("1.0.0")
      options.metadata.should be_empty
      options.transport.should be_nil
      options.codec.should be_nil
      options.registry.should be_nil
      options.broker.should be_nil
    end

    it "uses default version 'latest' when not specified" do
      options = Micro::Core::Service::Options.new(name: "test-service")
      options.version.should eq("latest")
    end
  end
end

describe Micro::Core::Service::Definition do
  describe "#initialize" do
    it "creates service definition" do
      metadata = HTTP::Headers{"env" => "production"}
      endpoints = ["api.get", "api.create", "api.update"]

      definition = Micro::Core::Service::Definition.new(
        name: "api-service",
        version: "1.0.0",
        metadata: metadata,
        endpoints: endpoints
      )

      definition.name.should eq("api-service")
      definition.version.should eq("1.0.0")
      definition.metadata.should eq(metadata)
      definition.endpoints.should eq(endpoints)
    end
  end
end

describe Micro::Core::Service do
  describe ".new with name and version" do
    it "creates a service with specified name and version" do
      service = Micro::Core::Service.new("my-service", "2.0.0")

      service.should be_a(Micro::Core::Service::Base)
      service.options.name.should eq("my-service")
      service.options.version.should eq("2.0.0")
    end

    it "uses default version when not specified" do
      service = Micro::Core::Service.new("my-service")

      service.options.name.should eq("my-service")
      service.options.version.should eq("latest")
    end
  end
end
