require "../../spec_helper"
require "../../../src/micro/stdlib/builder"

describe Micro::Stdlib do
  describe "NodeBuilder" do
    it "builds a valid node" do
      node = Micro::Stdlib::NodeBuilder.new
        .id("node-1")
        .address("192.168.1.1")
        .port(8080)
        .add_metadata("region", "us-west")
        .build!

      node.id.should eq("node-1")
      node.address.should eq("192.168.1.1")
      node.port.should eq(8080)
      node.metadata["region"].should eq("us-west")
    end

    it "validates required fields" do
      builder = Micro::Stdlib::NodeBuilder.new
      builder.valid?.should be_false
      builder.errors.should contain("id: is required")
      builder.errors.should contain("address: is required")
    end

    it "validates port range" do
      builder = Micro::Stdlib::NodeBuilder.new
        .id("node-1")
        .address("localhost")
        .port(99999)

      builder.valid?.should be_false
      builder.errors.should contain("port: must be between 0 and 65535")
    end

    it "validates address format" do
      builder = Micro::Stdlib::NodeBuilder.new
        .id("node-1")
        .address("not a valid address!")

      builder.valid?.should be_false
      builder.errors.should contain("address: must be a valid hostname or IP address")
    end

    it "provides default values" do
      node = Micro::Stdlib::NodeBuilder.new
        .id("node-1")
        .address("localhost")
        .build!

      node.port.should eq(0) # Default port
      node.metadata.should be_empty
    end
  end

  describe "TransportRequestBuilder" do
    it "builds a valid transport request" do
      request = Micro::Stdlib::TransportRequestBuilder.new
        .service("user-service")
        .method("GetUser")
        .body("test data".to_slice)
        .content_type("text/plain")
        .timeout(10.seconds)
        .add_header("X-Request-ID", "123")
        .build!

      request.service.should eq("user-service")
      request.method.should eq("GetUser")
      String.new(request.body).should eq("test data")
      request.content_type.should eq("text/plain")
      request.timeout.should eq(10.seconds)
      request.headers["X-Request-ID"].should eq("123")
    end

    it "supports JSON body helper" do
      data = {"name" => "Alice", "age" => 30}
      request = Micro::Stdlib::TransportRequestBuilder.new
        .service("user-service")
        .method("CreateUser")
        .json_body(data)
        .build!

      String.new(request.body).should eq(data.to_json)
      request.content_type.should eq("application/json")
    end

    it "validates required fields" do
      builder = Micro::Stdlib::TransportRequestBuilder.new
      builder.valid?.should be_false
      builder.errors.should contain("service: is required")
      builder.errors.should contain("method: is required")
      builder.errors.should contain("body: is required")
    end

    it "validates timeout" do
      builder = Micro::Stdlib::TransportRequestBuilder.new
        .service("test")
        .method("test")
        .body(Bytes.empty)
        .timeout(-1.seconds)

      builder.valid?.should be_false
      builder.errors.should contain("timeout: must be positive")
    end

    it "provides sensible defaults" do
      request = Micro::Stdlib::TransportRequestBuilder.new
        .service("test")
        .method("test")
        .body(Bytes.empty)
        .build!

      request.content_type.should eq("application/json")
      request.timeout.should eq(30.seconds)
      request.headers.should be_empty
    end

    it "raises on build! with invalid data" do
      builder = Micro::Stdlib::TransportRequestBuilder.new

      expect_raises(ArgumentError, /Builder validation failed/) do
        builder.build!
      end
    end
  end
end
