require "../spec_helper"
require "../../src/micro/stdlib/testing"

describe Micro::Gateway::APIGateway do
  it "routes GET /products to list" do
    svc = Micro::Stdlib::Testing::ServiceHarness.build("catalog") do
      handle "/list" do |ctx|
        arr = [] of JSON::Any
        arr << JSON::Any.new({"id" => JSON::Any.new("1"), "name" => JSON::Any.new("One")})
        arr << JSON::Any.new({"id" => JSON::Any.new("2"), "name" => JSON::Any.new("Two")})
        ctx.response.body = arr
      end
      handle "/get" do |ctx|
        id = ctx.request.body.as(JSON::Any).as_s
        if id == "1"
          ctx.response.body = {"id" => JSON::Any.new("1"), "name" => JSON::Any.new("One")}
        else
          ctx.response.status = 404
          ctx.response.body = {"error" => JSON::Any.new("not found")}
        end
      end
    end

    gateway = Micro::Stdlib::Testing.build_gateway do
      service "catalog" do
        route "GET", "/products", to: "list"
        route "POST", "/products/get", to: "get"
      end
    end

    status, headers, body = gateway.request("GET", "/products")
    status.should eq 200
    JSON.parse(body).as_a.size.should eq 2
  ensure
    svc.try(&.stop)
  end

  it "routes POST /products/get to get with JSON body" do
    svc = Micro::Stdlib::Testing::ServiceHarness.build("catalog") do
      handle "/list" do |ctx|
        arr = [] of JSON::Any
        arr << JSON::Any.new({"id" => JSON::Any.new("1"), "name" => JSON::Any.new("One")})
        arr << JSON::Any.new({"id" => JSON::Any.new("2"), "name" => JSON::Any.new("Two")})
        ctx.response.body = arr
      end
      handle "/get" do |ctx|
        id = ctx.request.body.as(JSON::Any).as_s
        if id == "1"
          ctx.response.body = {"id" => JSON::Any.new("1"), "name" => JSON::Any.new("One")}
        else
          ctx.response.status = 404
          ctx.response.body = {"error" => JSON::Any.new("not found")}
        end
      end
    end

    gateway = Micro::Stdlib::Testing.build_gateway do
      service "catalog" do
        route "GET", "/products", to: "list"
        route "POST", "/products/get", to: "get"
      end
    end

    status, headers, json = gateway.request_json("POST", "/products/get", JSON::Any.new("1"))
    status.should eq 200
    json["id"]?.should_not be_nil
  ensure
    svc.try(&.stop)
  end

  it "returns 404 for missing route" do
    svc = Micro::Stdlib::Testing::ServiceHarness.build("catalog") do
      handle "/list" do |ctx|
        arr = [] of JSON::Any
        arr << JSON::Any.new({"id" => JSON::Any.new("1"), "name" => JSON::Any.new("One")})
        arr << JSON::Any.new({"id" => JSON::Any.new("2"), "name" => JSON::Any.new("Two")})
        ctx.response.body = arr
      end
      handle "/get" do |ctx|
        id = String.new(ctx.request.body.as(Bytes))
        if id == "1"
          ctx.response.body = {"id" => "1", "name" => "One"}
        else
          ctx.response.status = 404
          ctx.response.body = {"error" => "not found"}
        end
      end
    end

    gateway = Micro::Stdlib::Testing.build_gateway do
      service "catalog" do
        route "GET", "/products", to: "list"
        route "POST", "/products/get", to: "get"
      end
    end

    status, headers, body = gateway.request("GET", "/missing")
    status.should eq 404
  ensure
    svc.try(&.stop)
  end
end
