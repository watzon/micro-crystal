require "../src/micro"

@[Micro::Service(name: "hello-service", version: "1.0.0")]
class HelloService
  include Micro::ServiceBase

  @[Micro::Method(description: "Say hello")]
  def hello(name : String) : String
    "Hello, #{name}!"
  end
end

# Start the service (binds to 0.0.0.0:8080 by default)
HelloService.run
