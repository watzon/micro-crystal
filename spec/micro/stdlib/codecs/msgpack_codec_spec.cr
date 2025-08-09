require "../../../spec_helper"
require "../../../../src/micro/stdlib/codecs/msgpack_codec"

# Test structs
struct TestUser
  include JSON::Serializable
  include MessagePack::Serializable

  property name : String
  property age : Int32
  property tags : Array(String)?

  def initialize(@name : String, @age : Int32, @tags : Array(String)? = nil)
  end

  def ==(other : TestUser)
    @name == other.name && @age == other.age && @tags == other.tags
  end
end

describe Micro::Stdlib::Codecs::MsgPackCodec do
  # Register codec for testing
  Spec.before_suite do
    Micro::Stdlib::Codecs::MsgPackCodec.register!
  end

  codec = Micro::Stdlib::Codecs::MsgPackCodec.new

  describe "#content_type" do
    it "returns the correct content type" do
      codec.content_type.should eq("application/msgpack")
    end
  end

  describe "#extension" do
    it "returns the correct file extension" do
      codec.extension.should eq("msgpack")
    end
  end

  describe "#name" do
    it "returns the human-readable name" do
      codec.name.should eq("MessagePack")
    end
  end

  describe "#marshal" do
    it "marshals basic types" do
      # String
      string_bytes = codec.marshal("hello")
      String.from_msgpack(string_bytes).should eq("hello")

      # Integer
      int_bytes = codec.marshal(42)
      Int32.from_msgpack(int_bytes).should eq(42)

      # Float
      float_bytes = codec.marshal(3.14)
      Float64.from_msgpack(float_bytes).should eq(3.14)

      # Boolean
      bool_bytes = codec.marshal(true)
      Bool.from_msgpack(bool_bytes).should eq(true)

      # Nil
      nil_bytes = codec.marshal(nil)
      Nil.from_msgpack(nil_bytes).should be_nil
    end

    it "marshals arrays" do
      array = [1, 2, 3, "four", true]
      bytes = codec.marshal(array)
      result = Array(MessagePack::Type).from_msgpack(bytes)
      result.should eq([1, 2, 3, "four", true])
    end

    it "marshals hashes" do
      hash = {"name" => "John", "age" => 30, "active" => true}
      bytes = codec.marshal(hash)
      result = Hash(String, MessagePack::Type).from_msgpack(bytes)
      result.should eq({"name" => "John", "age" => 30, "active" => true})
    end

    it "marshals complex objects with MessagePack::Serializable" do
      user = TestUser.new("Alice", 25, ["crystal", "ruby"])
      bytes = codec.marshal(user)
      restored = TestUser.from_msgpack(bytes)
      restored.should eq(user)
    end
  end

  describe "#unmarshal" do
    it "unmarshals basic types" do
      # String
      string_bytes = "hello".to_msgpack
      codec.unmarshal(string_bytes, String).should eq("hello")

      # Integer
      int_bytes = 42.to_msgpack
      codec.unmarshal(int_bytes, Int32).should eq(42)

      # Float
      float_bytes = 3.14.to_msgpack
      codec.unmarshal(float_bytes, Float64).should eq(3.14)

      # Boolean
      bool_bytes = true.to_msgpack
      codec.unmarshal(bool_bytes, Bool).should eq(true)
    end

    it "unmarshals arrays" do
      array = [1, 2, 3]
      bytes = array.to_msgpack
      result = codec.unmarshal(bytes, Array(Int32))
      result.should eq(array)
    end

    it "unmarshals hashes" do
      hash = {"key" => "value", "number" => 123}
      bytes = hash.to_msgpack
      result = codec.unmarshal(bytes, Hash(String, MessagePack::Type))
      result.should eq({"key" => "value", "number" => 123})
    end

    it "unmarshals complex objects with MessagePack::Serializable" do
      user = TestUser.new("Bob", 30, ["programming", "gaming"])
      bytes = user.to_msgpack
      result = codec.unmarshal(bytes, TestUser)
      result.should eq(user)
    end

    it "raises CodecError on unmarshal failure" do
      invalid_bytes = Bytes[0xFF, 0xFF, 0xFF]

      expect_raises(Micro::Core::CodecError, /Failed to/) do
        codec.unmarshal(invalid_bytes, String)
      end
    end

    it "raises CodecError on type mismatch" do
      string_bytes = "hello".to_msgpack

      expect_raises(Micro::Core::CodecError) do
        codec.unmarshal(string_bytes, Int32)
      end
    end
  end

  describe "#unmarshal?" do
    it "returns value on success" do
      bytes = "test".to_msgpack
      result = codec.unmarshal?(bytes, String)
      result.should eq("test")
    end

    it "returns nil on error" do
      invalid_bytes = Bytes[0xFF, 0xFF, 0xFF]
      result = codec.unmarshal?(invalid_bytes, String)
      result.should be_nil
    end
  end

  describe ".detect?" do
    it "detects valid MessagePack data" do
      # Various MessagePack formats
      Micro::Stdlib::Codecs::MsgPackCodec.detect?("string".to_msgpack).should be_true
      Micro::Stdlib::Codecs::MsgPackCodec.detect?(123.to_msgpack).should be_true
      Micro::Stdlib::Codecs::MsgPackCodec.detect?(true.to_msgpack).should be_true
      Micro::Stdlib::Codecs::MsgPackCodec.detect?([1, 2, 3].to_msgpack).should be_true
      Micro::Stdlib::Codecs::MsgPackCodec.detect?({"key" => "value"}.to_msgpack).should be_true
      Micro::Stdlib::Codecs::MsgPackCodec.detect?(nil.to_msgpack).should be_true
    end

    it "rejects non-MessagePack data" do
      # 0x01 is actually a valid positive fixint in MessagePack
      # Let's use bytes that are definitely not valid MessagePack
      Micro::Stdlib::Codecs::MsgPackCodec.detect?(Bytes[0xc1]).should be_false # 0xc1 is reserved/unused
      Micro::Stdlib::Codecs::MsgPackCodec.detect?(Bytes.empty).should be_false
    end

    it "rejects JSON data" do
      json_bytes = "{\"key\":\"value\"}".to_slice
      Micro::Stdlib::Codecs::MsgPackCodec.detect?(json_bytes).should be_false
    end
  end

  describe ".valid?" do
    it "validates correct MessagePack data" do
      Micro::Stdlib::Codecs::MsgPackCodec.valid?("test".to_msgpack).should be_true
      Micro::Stdlib::Codecs::MsgPackCodec.valid?([1, 2, 3].to_msgpack).should be_true
      Micro::Stdlib::Codecs::MsgPackCodec.valid?({"a" => 1}.to_msgpack).should be_true
    end

    it "rejects invalid MessagePack data" do
      # 0xFF is a valid negative fixint (-1), let's use truly invalid data
      Micro::Stdlib::Codecs::MsgPackCodec.valid?(Bytes[0xc1]).should be_false       # reserved byte
      Micro::Stdlib::Codecs::MsgPackCodec.valid?(Bytes[0xd4, 0xFF]).should be_false # incomplete fixext
      Micro::Stdlib::Codecs::MsgPackCodec.valid?(Bytes.empty).should be_false
    end
  end

  describe "#format_pretty" do
    it "pretty prints MessagePack data as JSON" do
      obj = {"name" => "Alice", "items" => [1, 2, 3]}
      pretty = codec.format_pretty(obj)

      pretty.should contain("{\n")
      pretty.should contain("  \"name\": \"Alice\"")
      pretty.should contain("  \"items\": [\n")
      pretty.should contain("    1,\n")
      pretty.should contain("    2,\n")
      pretty.should contain("    3\n")
      pretty.should contain("  ]")
    end

    it "handles nested structures" do
      obj = {
        "user" => {
          "name"     => "Bob",
          "settings" => {
            "theme" => "dark",
          },
        },
      }

      pretty = codec.format_pretty(obj)
      pretty.should contain("\"theme\": \"dark\"")
    end
  end

  describe "integration with CodecRegistry" do
    it "registers with the registry on require" do
      registry = Micro::Core::CodecRegistry.instance

      # Check main content type
      registry.has?("application/msgpack").should be_true
      registry.get("application/msgpack").should be_a(Micro::Stdlib::Codecs::MsgPackCodec)

      # Check aliases
      registry.has?("msgpack").should be_true
      registry.has?("application/x-msgpack").should be_true
      registry.has?("application/vnd.msgpack").should be_true
    end

    it "can be used through CodecHelpers" do
      user = TestUser.new("Charlie", 35)

      # Marshal
      bytes = Micro::Core::CodecHelpers.marshal(user, "application/msgpack")

      # Unmarshal
      result = Micro::Core::CodecHelpers.unmarshal(bytes, TestUser, "application/msgpack")
      result.should eq(user)
    end
  end

  describe "performance characteristics" do
    it "produces smaller output than JSON for numeric data" do
      data = {
        "values" => (1..100).to_a,
        "floats" => (1..50).map { |i| i * 3.14 },
      }

      msgpack_bytes = codec.marshal(data)
      json_bytes = data.to_json.to_slice

      # MessagePack should be more compact
      msgpack_bytes.size.should be < json_bytes.size
    end
  end
end
