require "../../spec_helper"
require "../../../src/micro/annotations"
require "../../../src/micro/macros/method_routing"

# Simple test service for basic macro functionality
@[Micro::Service(name: "basic-test", version: "1.0.0")]
class BasicTestService
  include Micro::Macros::MethodRouting

  @[Micro::Method(name: "hello")]
  def say_hello : String
    "Hello, World!"
  end

  @[Micro::Method(name: "greet", path: "/greet")]
  def greet(name : String) : String
    "Hello, #{name}!"
  end

  @[Micro::Method(name: "noop", path: "/noop")]
  def noop : Nil
    # Returns nothing
  end
end

describe "Micro::Macros::MethodRouting - Basic Tests" do
  it "extracts method information from annotations" do
    methods = BasicTestService.registered_methods
    methods.should_not be_nil
    methods.size.should eq 3

    # Check hello method
    hello = methods["/hello"]?
    hello.should_not be_nil
    h = hello.not_nil!
    h.name.should eq "hello"
    h.path.should eq "/hello"
    h.handler_name.should eq "say_hello"
    h.param_types.should eq [] of String
    h.return_type.should eq "String"

    # Check greet method
    greet = methods["/greet"]?
    greet.should_not be_nil
    g = greet.not_nil!
    g.name.should eq "greet"
    g.param_types.should eq ["String"]

    # Check noop method
    noop = methods["/noop"]?
    noop.should_not be_nil
    n = noop.not_nil!
    n.return_type.should eq "Nil"
  end

  it "generates list_methods helper" do
    methods = BasicTestService.list_methods
    methods.size.should eq 3

    method_names = methods.map(&.[:name])
    method_names.should contain "hello"
    method_names.should contain "greet"
    method_names.should contain "noop"

    # Check structure
    hello_method = methods.find { |method| method[:name] == "hello" }
    hello_method.should_not be_nil
    hm = hello_method.not_nil!
    hm[:path].should eq "/hello"
    hm[:http_method].should eq "POST"
  end
end
