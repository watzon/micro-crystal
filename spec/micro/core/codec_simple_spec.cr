require "../../spec_helper"

describe "Codec Interface - Basic Tests" do
  it "can register and use JSON codec" do
    registry = Micro::Core::CodecRegistry.instance

    # Should have JSON codec registered
    registry.has?("application/json").should be_true

    # Should be able to get the codec
    codec = registry.get("application/json")
    codec.should_not be_nil
    if codec
      codec.name.should eq("JSON")
    end
  end

  it "can marshal and unmarshal strings" do
    test_string = "hello world"

    # Marshal
    bytes = Micro::Core::CodecHelpers.marshal(test_string)
    bytes.should be_a(Bytes)

    # Check JSON format
    json_str = String.new(bytes)
    json_str.should eq("\"hello world\"")

    # Unmarshal
    result = Micro::Core::CodecHelpers.unmarshal(bytes, String)
    result.should eq("hello world")
  end

  it "can handle arrays" do
    test_array = [1, 2, 3]

    # Marshal
    bytes = Micro::Core::CodecHelpers.marshal(test_array)
    json_str = String.new(bytes)
    json_str.should eq("[1,2,3]")

    # Unmarshal
    result = Micro::Core::CodecHelpers.unmarshal(bytes, Array(Int32))
    result.should eq([1, 2, 3])
  end

  it "handles errors gracefully" do
    invalid_json = "invalid json".to_slice

    # Should return nil with safe unmarshal
    result = Micro::Core::CodecHelpers.unmarshal?(invalid_json, String)
    result.should be_nil

    # Should raise error with regular unmarshal
    expect_raises(Micro::Core::CodecError) do
      Micro::Core::CodecHelpers.unmarshal(invalid_json, String)
    end
  end

  it "can detect content types" do
    json_data = "\"test\"".to_slice
    detected = Micro::Core::CodecHelpers.detect_content_type(json_data)
    detected.should eq("application/json")
  end
end
