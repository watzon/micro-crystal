require "../../../spec_helper"

# Test struct for JSON serialization
struct TestStruct
  include ::JSON::Serializable

  property name : String
  property value : Int32
  property active : Bool

  def initialize(@name : String, @value : Int32, @active : Bool = true)
  end
end

describe Micro::Stdlib::Codecs::JSONCodec do
  codec = Micro::Stdlib::Codecs::JSONCodec.new

  describe "#content_type" do
    it "returns application/json" do
      codec.content_type.should eq("application/json")
    end
  end

  describe "#extension" do
    it "returns json" do
      codec.extension.should eq("json")
    end
  end

  describe "#name" do
    it "returns JSON" do
      codec.name.should eq("JSON")
    end
  end

  describe "#handles?" do
    it "returns true for application/json" do
      codec.handles?("application/json").should be_true
    end

    it "returns false for other content types" do
      codec.handles?("application/xml").should be_false
      codec.handles?("text/plain").should be_false
    end
  end

  describe "#marshal" do
    it "can marshal basic string" do
      data = "test string"

      bytes = codec.marshal(data)
      json_string = String.new(bytes)

      json_string.should eq("\"test string\"")
    end

    it "can marshal custom struct" do
      data = TestStruct.new("test", 42, true)

      bytes = codec.marshal(data)
      json_string = String.new(bytes)

      json_string.should contain("\"name\"")
      json_string.should contain("\"test\"")
      json_string.should contain("\"value\"")
      json_string.should contain("42")
      json_string.should contain("\"active\"")
      json_string.should contain("true")
    end

    it "can marshal arrays" do
      data = [1, 2, 3, 4, 5]

      bytes = codec.marshal(data)
      json_string = String.new(bytes)

      json_string.should eq("[1,2,3,4,5]")
    end
  end

  describe "#unmarshal" do
    it "can unmarshal to hash" do
      json_data = "{\"name\":\"test\",\"value\":42}".to_slice

      result = codec.unmarshal(json_data, Hash(String, ::JSON::Any))

      result["name"].as_s.should eq("test")
      result["value"].as_i.should eq(42)
    end

    it "can unmarshal to custom struct" do
      json_data = "{\"name\":\"test\",\"value\":42,\"active\":true}".to_slice

      result = codec.unmarshal(json_data, TestStruct)

      result.name.should eq("test")
      result.value.should eq(42)
      result.active.should be_true
    end

    it "can unmarshal arrays" do
      json_data = "[1,2,3,4,5]".to_slice

      result = codec.unmarshal(json_data, Array(Int32))

      result.should eq([1, 2, 3, 4, 5])
    end

    it "raises CodecError for invalid JSON" do
      invalid_json = "{ invalid json }".to_slice

      expect_raises(Micro::Core::CodecError, /Failed to parse JSON/) do
        codec.unmarshal(invalid_json, Hash(String, ::JSON::Any))
      end
    end

    it "raises CodecError for type mismatch" do
      # Try to unmarshal object to array
      json_data = "{\"name\":\"test\"}".to_slice

      expect_raises(Micro::Core::CodecError, /Failed to parse JSON/) do
        codec.unmarshal(json_data, Array(String))
      end
    end
  end

  describe "#unmarshal?" do
    it "returns result on success" do
      json_data = "{\"name\":\"test\",\"value\":42}".to_slice

      result = codec.unmarshal?(json_data, Hash(String, ::JSON::Any))

      result.should_not be_nil
      result.not_nil!["name"].as_s.should eq("test")
    end

    it "returns nil on error" do
      invalid_json = "{ invalid json }".to_slice

      result = codec.unmarshal?(invalid_json, Hash(String, ::JSON::Any))

      result.should be_nil
    end
  end

  describe ".detect?" do
    it "detects JSON objects" do
      json_object = "{\"key\": \"value\"}".to_slice
      Micro::Stdlib::Codecs::JSONCodec.detect?(json_object).should be_true
    end

    it "detects JSON arrays" do
      json_array = "[1, 2, 3]".to_slice
      Micro::Stdlib::Codecs::JSONCodec.detect?(json_array).should be_true
    end

    it "detects JSON strings" do
      json_string = "\"hello world\"".to_slice
      Micro::Stdlib::Codecs::JSONCodec.detect?(json_string).should be_true
    end

    it "detects JSON numbers" do
      json_number = "42".to_slice
      Micro::Stdlib::Codecs::JSONCodec.detect?(json_number).should be_true
    end

    it "detects JSON booleans" do
      json_true = "true".to_slice
      json_false = "false".to_slice

      Micro::Stdlib::Codecs::JSONCodec.detect?(json_true).should be_true
      Micro::Stdlib::Codecs::JSONCodec.detect?(json_false).should be_true
    end

    it "detects JSON null" do
      json_null = "null".to_slice
      Micro::Stdlib::Codecs::JSONCodec.detect?(json_null).should be_true
    end

    it "handles whitespace" do
      json_with_whitespace = "  \n  {\"key\": \"value\"}  ".to_slice
      Micro::Stdlib::Codecs::JSONCodec.detect?(json_with_whitespace).should be_true
    end

    it "returns false for non-JSON data" do
      non_json = "This is not JSON".to_slice
      Micro::Stdlib::Codecs::JSONCodec.detect?(non_json).should be_false
    end

    it "returns false for empty data" do
      empty = Bytes.empty
      Micro::Stdlib::Codecs::JSONCodec.detect?(empty).should be_false
    end
  end

  describe ".valid?" do
    it "returns true for valid JSON" do
      valid_json = "{\"key\": \"value\"}".to_slice
      Micro::Stdlib::Codecs::JSONCodec.valid?(valid_json).should be_true
    end

    it "returns false for invalid JSON" do
      invalid_json = "{ invalid json }".to_slice
      Micro::Stdlib::Codecs::JSONCodec.valid?(invalid_json).should be_false
    end
  end

  # Note: pretty_print and minify tests disabled due to JSON builder issues - see docs/TODO.md
  # describe "#pretty_print" do
  #   it "formats JSON with indentation" do
  #     data = TestStruct.new("test", 42, true)
  #
  #     pretty = codec.pretty_print(data)
  #
  #     pretty.should contain("\"name\": \"test\"")
  #     pretty.should contain("\"value\": 42")
  #     pretty.should contain("\"active\": true")
  #   end
  # end

  # describe "#minify" do
  #   it "removes whitespace from JSON" do
  #     spaced_json = "{\n  \"name\" : \"test\" ,\n  \"value\" : 42\n}".to_slice
  #
  #     minified = codec.minify(spaced_json)
  #     minified_string = String.new(minified)
  #
  #     minified_string.should_not contain(" ")
  #     minified_string.should_not contain("\n")
  #     minified_string.should contain("\"name\":\"test\"")
  #     minified_string.should contain("\"value\":42")
  #   end

  #   it "raises CodecError for invalid JSON" do
  #     invalid_json = "{ invalid json }".to_slice
  #
  #     expect_raises(Micro::Core::CodecError, /Failed to minify JSON/) do
  #       codec.minify(invalid_json)
  #     end
  #   end
  # end

  describe "auto-registration" do
    it "registers JSON codec in global registry" do
      # The codec should be auto-registered when the module is loaded
      registry = Micro::Core::CodecRegistry.instance

      json_codec = registry.get("application/json")
      json_codec.should_not be_nil
      json_codec.should be_a(Micro::Stdlib::Codecs::JSONCodec)
    end
  end
end

describe Micro::Stdlib::Codecs::JSON do
  describe ".new" do
    it "creates a new JSON codec instance" do
      codec = Micro::Stdlib::Codecs::JSON.new
      codec.should be_a(Micro::Stdlib::Codecs::JSONCodec)
    end
  end

  describe ".instance" do
    it "returns the registered JSON codec instance" do
      codec = Micro::Stdlib::Codecs::JSON.instance
      codec.should be_a(Micro::Stdlib::Codecs::JSONCodec)
      codec.content_type.should eq("application/json")
    end
  end
end
