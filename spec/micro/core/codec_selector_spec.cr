require "../../spec_helper"
require "../../../src/micro/core"
require "../../../src/micro/stdlib/codecs"
require "../../../src/micro/stdlib/codecs/msgpack_codec"

describe Micro::Core::CodecSelector do
  # Register codecs for testing
  Spec.before_suite do
    # Register MsgPack codec for this spec only
    Micro::Stdlib::Codecs::MsgPackCodec.register!
  end
  describe "#select_by_content_type" do
    it "selects codec by exact content type match" do
      selector = Micro::Core::CodecSelector.new

      codec = selector.select_by_content_type("application/json")
      codec.should be_a(Micro::Stdlib::Codecs::JSONCodec)
      codec.content_type.should eq("application/json")

      codec = selector.select_by_content_type("application/msgpack")
      codec.should be_a(Micro::Stdlib::Codecs::MsgPackCodec)
      codec.content_type.should eq("application/msgpack")
    end

    it "handles content type with charset parameter" do
      selector = Micro::Core::CodecSelector.new

      codec = selector.select_by_content_type("application/json; charset=utf-8")
      codec.should be_a(Micro::Stdlib::Codecs::JSONCodec)
    end

    it "handles content type aliases" do
      selector = Micro::Core::CodecSelector.new

      # JSON aliases
      codec = selector.select_by_content_type("application/x-json")
      codec.should be_a(Micro::Stdlib::Codecs::JSONCodec)

      codec = selector.select_by_content_type("text/json")
      codec.should be_a(Micro::Stdlib::Codecs::JSONCodec)

      # MsgPack aliases
      codec = selector.select_by_content_type("application/x-msgpack")
      codec.content_type.should eq("application/x-msgpack")

      codec = selector.select_by_content_type("msgpack")
      codec.content_type.should eq("msgpack")
    end

    it "returns default codec for unknown content types" do
      selector = Micro::Core::CodecSelector.new

      codec = selector.select_by_content_type("application/unknown")
      codec.should be_a(Micro::Stdlib::Codecs::JSONCodec) # JSON is default
    end

    it "returns default codec for nil or empty content type" do
      selector = Micro::Core::CodecSelector.new

      codec = selector.select_by_content_type(nil)
      codec.should be_a(Micro::Stdlib::Codecs::JSONCodec)

      codec = selector.select_by_content_type("")
      codec.should be_a(Micro::Stdlib::Codecs::JSONCodec)
    end

    it "handles wildcard content types" do
      selector = Micro::Core::CodecSelector.new

      codec = selector.select_by_content_type("*/*")
      codec.should be_a(Micro::Stdlib::Codecs::JSONCodec)

      codec = selector.select_by_content_type("application/*")
      codec.should be_a(Micro::Stdlib::Codecs::JSONCodec)
    end
  end

  describe "#select_by_accept" do
    it "selects codec based on simple accept header" do
      selector = Micro::Core::CodecSelector.new

      codec = selector.select_by_accept("application/json")
      codec.should be_a(Micro::Stdlib::Codecs::JSONCodec)

      codec = selector.select_by_accept("application/msgpack")
      codec.should be_a(Micro::Stdlib::Codecs::MsgPackCodec)
    end

    it "handles accept header with quality values" do
      selector = Micro::Core::CodecSelector.new

      # Prefer msgpack over json
      codec = selector.select_by_accept("application/json;q=0.8, application/msgpack;q=0.9")
      codec.should be_a(Micro::Stdlib::Codecs::MsgPackCodec)

      # Prefer json over msgpack
      codec = selector.select_by_accept("application/json;q=0.9, application/msgpack;q=0.8")
      codec.should be_a(Micro::Stdlib::Codecs::JSONCodec)
    end

    it "handles accept header with multiple types" do
      selector = Micro::Core::CodecSelector.new

      codec = selector.select_by_accept("text/html, application/json, */*")
      codec.should be_a(Micro::Stdlib::Codecs::JSONCodec)
    end

    it "ignores unsupported types in accept header" do
      selector = Micro::Core::CodecSelector.new

      codec = selector.select_by_accept("text/html, application/xml, application/json")
      codec.should be_a(Micro::Stdlib::Codecs::JSONCodec)
    end

    it "returns default codec for unsupported accept header" do
      selector = Micro::Core::CodecSelector.new

      codec = selector.select_by_accept("text/html, application/xml")
      codec.should be_a(Micro::Stdlib::Codecs::JSONCodec)
    end
  end

  describe "#negotiate" do
    it "prefers content-type over accept header" do
      selector = Micro::Core::CodecSelector.new

      codec = selector.negotiate("application/json", "application/msgpack")
      codec.should be_a(Micro::Stdlib::Codecs::MsgPackCodec)
    end

    it "uses accept header when content-type is not specified" do
      selector = Micro::Core::CodecSelector.new

      codec = selector.negotiate("application/msgpack", nil)
      codec.should be_a(Micro::Stdlib::Codecs::MsgPackCodec)

      codec = selector.negotiate("application/msgpack", "")
      codec.should be_a(Micro::Stdlib::Codecs::MsgPackCodec)
    end
  end

  describe "#detect_from_data" do
    it "detects JSON data" do
      selector = Micro::Core::CodecSelector.new

      json_data = %q({"name": "test"}).to_slice
      codec = selector.detect_from_data(json_data)
      codec.should be_a(Micro::Stdlib::Codecs::JSONCodec)

      json_array = %q([1, 2, 3]).to_slice
      codec = selector.detect_from_data(json_array)
      codec.should be_a(Micro::Stdlib::Codecs::JSONCodec)
    end

    it "detects MessagePack data" do
      selector = Micro::Core::CodecSelector.new

      # Create actual msgpack data
      msgpack_data = {"name" => "test"}.to_msgpack
      codec = selector.detect_from_data(msgpack_data)
      codec.should be_a(Micro::Stdlib::Codecs::MsgPackCodec)
    end

    it "returns nil for empty data" do
      selector = Micro::Core::CodecSelector.new

      codec = selector.detect_from_data(Bytes.empty)
      codec.should be_nil
    end

    it "returns nil for unrecognizable data" do
      selector = Micro::Core::CodecSelector.new

      # Use bytes that are invalid for both JSON and MsgPack
      # 0xC1 is explicitly reserved/unused in msgpack spec
      random_data = Bytes[0xC1, 0x00, 0x00]
      codec = selector.detect_from_data(random_data)
      codec.should be_nil
    end
  end

  describe "#select_with_fallback" do
    it "tries content-type first" do
      selector = Micro::Core::CodecSelector.new

      codec = selector.select_with_fallback("application/msgpack", "application/json", nil)
      codec.should be_a(Micro::Stdlib::Codecs::MsgPackCodec)
    end

    it "falls back to accept header" do
      selector = Micro::Core::CodecSelector.new

      codec = selector.select_with_fallback(nil, "application/msgpack", nil)
      codec.should be_a(Micro::Stdlib::Codecs::MsgPackCodec)
    end

    it "falls back to data detection" do
      selector = Micro::Core::CodecSelector.new

      msgpack_data = [1, 2, 3].to_msgpack
      codec = selector.select_with_fallback(nil, nil, msgpack_data)
      codec.should be_a(Micro::Stdlib::Codecs::MsgPackCodec)
    end

    it "falls back to default codec" do
      selector = Micro::Core::CodecSelector.new

      codec = selector.select_with_fallback(nil, nil, nil)
      codec.should be_a(Micro::Stdlib::Codecs::JSONCodec)
    end
  end

  describe "custom default codec" do
    it "uses custom default codec when specified" do
      msgpack_codec = Micro::Stdlib::Codecs::MsgPackCodec.new
      selector = Micro::Core::CodecSelector.new(default_codec: msgpack_codec)

      codec = selector.select_by_content_type("application/unknown")
      codec.should be_a(Micro::Stdlib::Codecs::MsgPackCodec)
    end
  end

  describe "singleton instance" do
    it "provides a global instance" do
      instance1 = Micro::Core::CodecSelector.instance
      instance2 = Micro::Core::CodecSelector.instance

      instance1.should be(instance2)
    end

    it "can reset the global instance" do
      instance1 = Micro::Core::CodecSelector.instance
      Micro::Core::CodecSelector.reset_instance
      instance2 = Micro::Core::CodecSelector.instance

      instance1.should_not be(instance2)
    end
  end
end
