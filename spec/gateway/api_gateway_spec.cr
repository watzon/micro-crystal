require "../spec_helper"
require "../../src/micro/gateway"

describe Micro::Gateway::APIGateway do
  describe "configuration" do
    it "initializes with default config" do
      config = Micro::Gateway::Config.new
      gateway = Micro::Gateway::APIGateway.new(config)

      gateway.config.name.should eq "api-gateway"
      gateway.config.version.should eq "1.0.0"
      gateway.config.host.should eq "0.0.0.0"
      gateway.config.port.should eq 8080
    end

    it "accepts custom configuration" do
      config = Micro::Gateway::Config.new(
        name: "my-gateway",
        version: "2.0.0",
        host: "localhost",
        port: 3000
      )
      gateway = Micro::Gateway::APIGateway.new(config)

      gateway.config.name.should eq "my-gateway"
      gateway.config.version.should eq "2.0.0"
      gateway.config.host.should eq "localhost"
      gateway.config.port.should eq 3000
    end
  end

  describe "route registration" do
    it "registers routes from service config" do
      config = Micro::Gateway::Config.new

      service_config = Micro::Gateway::ServiceConfig.new
      service_config.add_route(Micro::Gateway::RouteConfig.new(
        method: "GET",
        path: "/api/users/:id",
        service_method: "GetUser"
      ))

      config.add_service("user-service", service_config)

      gateway = Micro::Gateway::APIGateway.new(config)

      # Routes should be registered
      routes = gateway.routes.for_service("user-service")
      routes.size.should eq 1
      routes.first.path.should eq "/api/users/:id"
    end
  end

  describe "DSL builder" do
    it "builds gateway with DSL" do
      gateway = Micro::Gateway.build do
        name "test-gateway"
        version "1.0.0"
        host "127.0.0.1"
        port 8081

        service "user-service" do
          expose :get_user, :create_user
          prefix "/api/users"
          timeout 5.seconds
        end
      end

      gateway.config.name.should eq "test-gateway"
      gateway.config.port.should eq 8081
      gateway.config.services.has_key?("user-service").should be_true
    end
  end

  describe "service filtering" do
    it "respects exposed methods whitelist" do
      service_config = Micro::Gateway::ServiceConfig.new(
        exposed_methods: ["GetUser", "CreateUser"]
      )

      service_config.method_exposed?("GetUser").should be_true
      service_config.method_exposed?("CreateUser").should be_true
      service_config.method_exposed?("DeleteUser").should be_false
    end

    it "respects blocked methods blacklist" do
      service_config = Micro::Gateway::ServiceConfig.new(
        blocked_methods: ["DeleteUser", "UpdateUser"]
      )

      service_config.method_exposed?("GetUser").should be_true
      service_config.method_exposed?("DeleteUser").should be_false
      service_config.method_exposed?("UpdateUser").should be_false
    end
  end

  describe "response transformations" do
    it "removes specified fields" do
      transformation = Micro::Gateway::ResponseTransformation.new(
        type: Micro::Gateway::ResponseTransformation::TransformationType::RemoveFields,
        fields_to_remove: ["password", "internal_id"]
      )

      original = JSON::Any.new({
        "id"          => JSON::Any.new("123"),
        "name"        => JSON::Any.new("John"),
        "password"    => JSON::Any.new("secret"),
        "internal_id" => JSON::Any.new("int456"),
      })

      result = transformation.apply(original)
      result.as_h.has_key?("id").should be_true
      result.as_h.has_key?("name").should be_true
      result.as_h.has_key?("password").should be_false
      result.as_h.has_key?("internal_id").should be_false
    end

    it "adds specified fields" do
      transformation = Micro::Gateway::ResponseTransformation.new(
        type: Micro::Gateway::ResponseTransformation::TransformationType::AddFields,
        fields_to_add: {
          "api_version" => JSON::Any.new("1.0"),
          "timestamp"   => JSON::Any.new(Time.utc.to_unix),
        }
      )

      original = JSON::Any.new({
        "id"   => JSON::Any.new("123"),
        "name" => JSON::Any.new("John"),
      })

      result = transformation.apply(original)
      result.as_h.has_key?("api_version").should be_true
      result.as_h["api_version"].should eq JSON::Any.new("1.0")
    end
  end
end
