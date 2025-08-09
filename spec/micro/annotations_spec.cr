require "../spec_helper"
require "../../src/micro/annotations"

# Test classes to verify annotation usage
@[Micro::Service(name: "test-service", version: "1.2.3")]
class TestServiceWithVersion
end

@[Micro::Service(name: "minimal-service")]
class MinimalService
end

@[Micro::Service(
  name: "full-service",
  version: "2.0.0",
  namespace: "test",
  description: "A test service",
  metadata: {"env" => "test", "region" => "us-west"}
)]
class FullyAnnotatedService
  @[Micro::Method]
  def default_method
  end

  @[Micro::Method(name: "custom_name", path: "/api/test", http_method: "GET")]
  def annotated_method
  end

  @[Micro::Method(auth_required: true, timeout: 60)]
  @[Micro::Middleware(["auth", "logging"])]
  def protected_method
  end

  @[Micro::Subscribe(topic: "test.event")]
  def handle_event(data : String)
  end

  @[Micro::Subscribe(topic: "test.queue", queue_group: "workers", max_retries: 5)]
  def handle_queue_event(data : String)
  end

  @[Micro::Handler(streaming: true, compress: true)]
  def streaming_handler
  end
end

describe "Micro::Annotations" do
  describe "Service annotation" do
    it "can be applied to a class with minimal configuration" do
      # This test verifies the annotation compiles
      MinimalService.should_not be_nil
    end

    it "can be applied with all fields" do
      # This test verifies the annotation compiles with all fields
      FullyAnnotatedService.should_not be_nil
    end

    pending "can be accessed via macros" do
      # This will be tested when macros are implemented
      # {{ MinimalService.annotation(Micro::Service) }} should return annotation data
    end
  end

  describe "Method annotation" do
    it "can be applied without arguments" do
      service = FullyAnnotatedService.new
      service.responds_to?(:default_method).should be_true
    end

    it "can be applied with custom configuration" do
      service = FullyAnnotatedService.new
      service.responds_to?(:annotated_method).should be_true
    end

    it "can be combined with Middleware annotation" do
      service = FullyAnnotatedService.new
      service.responds_to?(:protected_method).should be_true
    end
  end

  describe "Subscribe annotation" do
    it "can be applied with minimal configuration" do
      service = FullyAnnotatedService.new
      service.responds_to?(:handle_event).should be_true
    end

    it "can be applied with queue group and retry settings" do
      service = FullyAnnotatedService.new
      service.responds_to?(:handle_queue_event).should be_true
    end
  end

  describe "Handler annotation" do
    it "can configure streaming handlers" do
      service = FullyAnnotatedService.new
      service.responds_to?(:streaming_handler).should be_true
    end
  end

  describe "Annotation combinations" do
    it "allows multiple annotations on the same method" do
      # Verified by protected_method having both Method and Middleware annotations
      service = FullyAnnotatedService.new
      service.responds_to?(:protected_method).should be_true
    end
  end
end

# Example of what macro processing will look like in the future
# describe "Future macro processing" do
#   pending "extracts service metadata" do
#     # {% if FullyAnnotatedService.annotation(Micro::Service) %}
#     #   name = {{ FullyAnnotatedService.annotation(Micro::Service)[:name] }}
#     #   version = {{ FullyAnnotatedService.annotation(Micro::Service)[:version] }}
#     #   name.should eq("full-service")
#     #   version.should eq("2.0.0")
#     # {% end %}
#   end
#
#   pending "generates handler registration" do
#     # Macros will generate code like:
#     # server.register_handler("custom_name", ->annotated_method)
#     # server.register_subscription("test.event", ->handle_event)
#   end
# end
