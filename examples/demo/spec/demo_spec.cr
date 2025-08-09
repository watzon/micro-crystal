require "./spec_helper"

describe "Demo integration" do
  # Start services using in-process harnesses
  harness("catalog") do
    handle("/list_products") do |ctx|
      ctx.response.status = 200
      ctx.response.body = JSON::Any.new([
        JSON::Any.new({
          "id" => JSON::Any.new("p-1"),
          "name" => JSON::Any.new("Sample Product"),
          "price" => JSON::Any.new(9.99),
        })
      ])
    end
    handle("/get_product") do |ctx|
      # Body may be JSON::Any with merged path params from the gateway
      id = nil
      case body = ctx.request.body
      when JSON::Any
        id = body.as_h["id"]?.try(&.as_s?)
      when Bytes
        begin
          id = JSON.parse(String.new(body)).as_h["id"]?.try(&.as_s?)
        rescue
          id = nil
        end
      end

      if id == "p-1"
        ctx.response.status = 200
        ctx.response.body = JSON::Any.new({
          "id" => JSON::Any.new("p-1"),
          "name" => JSON::Any.new("Sample Product"),
          "price" => JSON::Any.new(9.99),
        })
      else
        ctx.response.status = 404
        ctx.response.body = JSON::Any.new({"error" => JSON::Any.new("Not found")})
      end
    end
  end

  harness("orders") do
    handle("/create_order") do |ctx|
      ctx.response.status = 200
      ctx.response.body = JSON::Any.new({
        "id" => JSON::Any.new("o-1"),
        "total" => JSON::Any.new(19.98),
        "items" => JSON::Any.new([
          JSON::Any.new({"product_id" => JSON::Any.new("p-1"), "quantity" => JSON::Any.new(2)})
        ])
      })
    end
    handle("/get_order") do |ctx|
      ctx.response.status = 200
      ctx.response.body = JSON::Any.new({
        "id" => JSON::Any.new("o-1"),
        "total" => JSON::Any.new(19.98),
        "items" => JSON::Any.new([
          JSON::Any.new({"product_id" => JSON::Any.new("p-1"), "quantity" => JSON::Any.new(2)})
        ])
      })
    end
  end

  # Define gateway via macro and get a test client
  gateway("demo-gateway") do
    name "demo-gateway"
    version "1.0.0"
    host "127.0.0.1"
    port 0

    service "catalog" do
      version "1.0.0"
      prefix "/api/catalog"
      rest_routes "/products" do
        index :list_products
        show :get_product
      end
    end

    service "orders" do
      version "1.0.0"
      prefix "/api/orders"
      route "POST", "", to: "create_order"
      rest_routes "/orders" do
        show :get_order
      end
    end
  end

  it "serves catalog endpoints via the gateway" do
    begin
      client = Micro::Stdlib::Testing::GatewayRegistry.fetch!("demo-gateway")

      status, _headers, body = client.request("GET", "/api/catalog/products")
      status.should eq 200
      body.should contain("Sample Product")

      status2, _h2, body2 = client.request("GET", "/api/catalog/products/p-1")
      status2.should eq 200
      body2.should contain("\"p-1\"")

      status3, _h3, body3 = client.request_json("POST", "/api/orders", {"items" => [{"product_id" => "p-1", "quantity" => 2}]})
      status3.should eq 200
      body3.as_h["id"].as_s.should_not be_empty
    ensure
      Micro::Stdlib::Testing::HarnessRegistry.fetch("catalog").try(&.stop)
      Micro::Stdlib::Testing::HarnessRegistry.fetch("orders").try(&.stop)
    end
  end
end
