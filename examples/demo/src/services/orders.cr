require "micro"

@[Micro::Service(name: "orders", version: "1.0.0")]
@[Micro::Middleware(["request_id", "logging", "timing", "error_handler"])]
class OrderService
  include Micro::ServiceBase

  # Local view of catalog product for deserialization
  struct CatalogProduct
    include JSON::Serializable
    getter id : String
    getter name : String
    getter price : Float64
  end

  struct OrderItem
    include JSON::Serializable
    getter product_id : String
    getter quantity : Int32
  end

  struct CreateOrder
    include JSON::Serializable
    getter items : Array(OrderItem)
  end

  struct Order
    include JSON::Serializable
    getter id : String
    getter total : Float64
    getter items : Array(OrderItem)
    getter created_at : Time

    def initialize(@id : String, @total : Float64, @items : Array(OrderItem), @created_at : Time)
    end
  end

  @@orders : Hash(String, Order) = {} of String => Order

  @[Micro::Method]
  def create_order(input : CreateOrder) : Order
    total = input.items.sum do |item|
      product = fetch_catalog_product(item.product_id) || raise ArgumentError.new("Unknown product: #{item.product_id}")
      product.price * item.quantity
    end

    order = Order.new(
      id: UUID.random.to_s,
      total: total,
      items: input.items,
      created_at: Time.utc
    )
    @@orders[order.id] = order
    order
  end

  @[Micro::Method]
  def get_order(id : String) : Order?
    @@orders[id]?
  end

  private def fetch_catalog_product(product_id : String)
    response = client.call(
      service: "catalog",
      method: "/get_product",
      body: %("#{product_id}").to_slice
    )
    return nil if response.status >= 400
    json = String.new(response.body)
    return nil if json == "null"
    CatalogProduct.from_json(json)
  end
end
