require "micro"

@[Micro::Service(name: "catalog", version: "1.0.0")]
@[Micro::Middleware([
  "request_id", "logging", "timing", "error_handler", "cors", "compression",
])]
class CatalogService
  include Micro::ServiceBase

  struct Product
    include JSON::Serializable
    getter id : String
    getter name : String
    getter price : Float64
  end

  @@products : Hash(String, Product) = begin
    seed = {} of String => Product
    seed_json = {"id" => "p-1", "name" => "Sample Product", "price" => 9.99}.to_json
    seed["p-1"] = Product.from_json(seed_json)
    seed
  end

  @[Micro::Method]
  @[Micro::AllowAnonymous]
  def list_products : Array(Product)
    @@products.values
  end

  @[Micro::Method]
  @[Micro::AllowAnonymous]
  def get_product(id : String) : Product?
    @@products[id]?
  end
end
