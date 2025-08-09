require "../../spec_helper"

describe Micro::Core::Context do
  describe "#initialize" do
    it "creates a context with request and response" do
      request = Micro::Core::Request.new("test-service", "test-endpoint")
      response = Micro::Core::Response.new
      context = Micro::Core::Context.new(request, response)

      context.request.should eq(request)
      context.response.should eq(response)
      context.metadata.should be_empty
      context.error.should be_nil
    end
  end

  describe "#[] and #[]=" do
    it "allows getting and setting metadata" do
      context = Micro::Core::Context.background

      context["key"].should be_nil
      context["key"] = "value"
      context["key"].should eq("value")
    end

    it "stores multiple metadata entries" do
      context = Micro::Core::Context.background

      context["key1"] = "value1"
      context["key2"] = "value2"

      context["key1"].should eq("value1")
      context["key2"].should eq("value2")
      context.metadata.size.should eq(2)
    end
  end

  describe "#error?" do
    it "returns false when no error" do
      context = Micro::Core::Context.background
      context.error?.should be_false
    end

    it "returns true when error is set" do
      context = Micro::Core::Context.background
      context.error = Exception.new("test error")
      context.error?.should be_true
    end
  end

  describe "#set_error" do
    it "sets error and updates response" do
      context = Micro::Core::Context.background
      error = Exception.new("Something went wrong")

      context.set_error(error)

      context.error.should eq(error)
      context.response.status.should eq(500)
      context.response.body.should eq({"error" => "Something went wrong"})
    end

    it "handles errors without messages" do
      context = Micro::Core::Context.background
      error = Exception.new

      context.set_error(error)

      context.error.should eq(error)
      context.response.status.should eq(500)
      context.response.body.should eq({"error" => "Internal server error"})
    end
  end

  describe ".background" do
    it "creates a context for testing" do
      context = Micro::Core::Context.background

      context.request.service.should eq("test")
      context.request.endpoint.should eq("test")
      context.request.content_type.should eq("application/json")
      context.request.body.should be_nil
      context.response.status.should eq(200)
    end
  end
end

describe Micro::Core::Request do
  describe "#initialize" do
    it "creates request with required fields" do
      request = Micro::Core::Request.new("my-service", "my-endpoint")

      request.service.should eq("my-service")
      request.endpoint.should eq("my-endpoint")
      request.content_type.should eq("application/json")
      request.headers.should be_empty
      request.body.should be_nil
    end

    it "creates request with all fields" do
      headers = HTTP::Headers{"X-Custom" => "value"}
      body = "test body".to_slice

      request = Micro::Core::Request.new(
        service: "my-service",
        endpoint: "my-endpoint",
        content_type: "text/plain",
        headers: headers,
        body: body
      )

      request.service.should eq("my-service")
      request.endpoint.should eq("my-endpoint")
      request.content_type.should eq("text/plain")
      request.headers.should eq(headers)
      request.body.should eq(body)
    end

    it "supports JSON::Any as body" do
      json_body = JSON.parse(%({"key": "value"}))
      request = Micro::Core::Request.new("service", "endpoint", body: json_body)

      request.body.should eq(json_body)
    end
  end

  describe "#header" do
    it "gets header value" do
      headers = HTTP::Headers{"X-Custom" => "value"}
      request = Micro::Core::Request.new("service", "endpoint", headers: headers)

      request.header("X-Custom").should eq("value")
      request.header("X-Missing").should be_nil
    end

    it "sets header value" do
      request = Micro::Core::Request.new("service", "endpoint")

      request.header("X-Custom", "value").should eq("value")
      request.header("X-Custom").should eq("value")
    end

    it "overwrites existing header" do
      request = Micro::Core::Request.new("service", "endpoint")

      request.header("X-Custom", "value1")
      request.header("X-Custom", "value2")
      request.header("X-Custom").should eq("value2")
    end
  end

  describe "property setters" do
    it "allows modifying properties after creation" do
      request = Micro::Core::Request.new("service", "endpoint")

      request.service = "new-service"
      request.endpoint = "new-endpoint"
      request.content_type = "text/plain"
      request.body = "data".to_slice

      request.service.should eq("new-service")
      request.endpoint.should eq("new-endpoint")
      request.content_type.should eq("text/plain")
      request.body.should eq("data".to_slice)
    end
  end
end

describe Micro::Core::Response do
  describe "#initialize" do
    it "creates response with defaults" do
      response = Micro::Core::Response.new

      response.status.should eq(200)
      response.headers.should be_empty
      response.body.should be_nil
    end

    it "creates response with custom values" do
      headers = HTTP::Headers{"Content-Type" => "text/plain"}
      body = {"message" => "Hello"}

      response = Micro::Core::Response.new(
        status: 201,
        headers: headers,
        body: body
      )

      response.status.should eq(201)
      response.headers.should eq(headers)
      response.body.should eq(body)
    end

    it "supports different body types" do
      # Bytes
      bytes_response = Micro::Core::Response.new(body: "data".to_slice)
      bytes_response.body.should eq("data".to_slice)

      # JSON::Any
      json_response = Micro::Core::Response.new(body: JSON.parse(%({"key": "value"})))
      json_response.body.as(JSON::Any)["key"].should eq("value")

      # Hash
      hash_response = Micro::Core::Response.new(body: {"key" => "value"})
      hash_response.body.should eq({"key" => "value"})
    end
  end

  describe "#header" do
    it "gets header value" do
      headers = HTTP::Headers{"Content-Type" => "application/json"}
      response = Micro::Core::Response.new(headers: headers)

      response.header("Content-Type").should eq("application/json")
      response.header("X-Missing").should be_nil
    end

    it "sets header value" do
      response = Micro::Core::Response.new

      response.header("X-Custom", "value").should eq("value")
      response.header("X-Custom").should eq("value")
    end
  end

  describe "#success?" do
    it "returns true for 2xx status codes" do
      Micro::Core::Response.new(status: 200).success?.should be_true
      Micro::Core::Response.new(status: 201).success?.should be_true
      Micro::Core::Response.new(status: 204).success?.should be_true
      Micro::Core::Response.new(status: 299).success?.should be_true
    end

    it "returns false for non-2xx status codes" do
      Micro::Core::Response.new(status: 100).success?.should be_false
      Micro::Core::Response.new(status: 300).success?.should be_false
      Micro::Core::Response.new(status: 400).success?.should be_false
      Micro::Core::Response.new(status: 500).success?.should be_false
    end
  end

  describe "#error?" do
    it "returns false for 2xx status codes" do
      Micro::Core::Response.new(status: 200).error?.should be_false
      Micro::Core::Response.new(status: 201).error?.should be_false
    end

    it "returns true for non-2xx status codes" do
      Micro::Core::Response.new(status: 400).error?.should be_true
      Micro::Core::Response.new(status: 404).error?.should be_true
      Micro::Core::Response.new(status: 500).error?.should be_true
    end
  end

  describe "property setters" do
    it "allows modifying properties after creation" do
      response = Micro::Core::Response.new

      response.status = 404
      response.body = {"error" => "Not found"}

      response.status.should eq(404)
      response.body.should eq({"error" => "Not found"})
      response.error?.should be_true
    end
  end
end
