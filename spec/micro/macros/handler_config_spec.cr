require "../../spec_helper"
require "../../../src/micro/annotations"
require "../../../src/micro/macros/handler_config"

# Test service with handler configurations
@[Micro::Service(name: "test-handler-service")]
class TestHandlerService
  include Micro::Macros::HandlerConfig

  @[Micro::Handler(streaming: true, compress: true, max_message_size: 1048576)]
  def stream_data
    # Streaming method
  end

  @[Micro::Handler(compress: true, timeout: 30)]
  def compressed_method
    # Compressed method with timeout
  end

  @[Micro::Handler(
    streaming: false,
    compress: false,
    middlewares: ["auth", "logging"],
    error_handler: "custom_error_handler",
    codec: "msgpack"
  )]
  def configured_method
    # Fully configured method
  end

  # Method without handler annotation
  def regular_method
    # No special configuration
  end
end

describe Micro::Macros::HandlerConfig do
  describe "handler configuration extraction" do
    it "extracts streaming configuration" do
      config = TestHandlerService.handler_config("stream_data")
      config.should_not be_nil
      cfg = config.not_nil!
      cfg.streaming.should be_true
      cfg.compress.should be_true
      cfg.max_message_size.should eq 1048576
    end

    it "extracts compress and timeout configuration" do
      config = TestHandlerService.handler_config("compressed_method")
      config.should_not be_nil
      cfg = config.not_nil!
      cfg.compress.should be_true
      cfg.timeout.should eq 30
      cfg.streaming.should be_false
    end

    it "extracts full configuration" do
      config = TestHandlerService.handler_config("configured_method")
      config.should_not be_nil
      cfg = config.not_nil!
      cfg.streaming.should be_false
      cfg.compress.should be_false
      cfg.middlewares.should eq ["auth", "logging"]
      cfg.error_handler.should eq "custom_error_handler"
      cfg.codec.should eq "msgpack"
    end

    it "returns nil for methods without handler annotation" do
      config = TestHandlerService.handler_config("regular_method")
      config.should be_nil
    end

    it "returns nil for non-existent methods" do
      config = TestHandlerService.handler_config("non_existent")
      config.should be_nil
    end
  end

  describe "streaming check helper" do
    it "correctly identifies streaming handlers" do
      TestHandlerService.is_streaming_handler?("stream_data").should be_true
      TestHandlerService.is_streaming_handler?("compressed_method").should be_false
      TestHandlerService.is_streaming_handler?("configured_method").should be_false
      TestHandlerService.is_streaming_handler?("regular_method").should be_false
    end
  end

  describe "configured handlers list" do
    it "lists all handlers with configuration" do
      handlers = TestHandlerService.configured_handlers
      handlers.size.should eq 3

      stream_handler = handlers.find { |handler| handler[:name] == "stream_data" }
      stream_handler.should_not be_nil
      sh = stream_handler.not_nil!
      sh[:streaming].should be_true
      sh[:compress].should be_true

      compressed_handler = handlers.find { |handler| handler[:name] == "compressed_method" }
      compressed_handler.should_not be_nil
      ch = compressed_handler.not_nil!
      ch[:streaming].should be_false
      ch[:compress].should be_true
    end
  end
end
