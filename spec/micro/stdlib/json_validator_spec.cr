require "../../spec_helper"
require "../../../src/micro/stdlib/json_validator"

# Test struct for parse_as specs
struct JSONTestUser
  include JSON::Serializable

  property name : String
  property age : Int32

  def initialize(@name : String, @age : Int32)
  end
end

describe Micro::Stdlib::JSONValidator do
  describe ".parse" do
    it "parses valid JSON" do
      result = Micro::Stdlib::JSONValidator.parse(%{{"name": "test", "age": 25}})
      result.success?.should be_true
      result.data.should_not be_nil
      if data = result.data
        data["name"].as_s.should eq("test")
        data["age"].as_i.should eq(25)
      end
    end

    it "handles parse errors gracefully" do
      result = Micro::Stdlib::JSONValidator.parse(%{{"invalid": json}})
      result.failure?.should be_true
      result.errors.should_not be_empty
      result.errors.first.should contain("JSON parse error")
    end

    it "handles empty input" do
      result = Micro::Stdlib::JSONValidator.parse("")
      result.failure?.should be_true
      result.errors.should_not be_empty
    end
  end

  describe "Schema validation" do
    it "validates required fields" do
      schema = Micro::Stdlib::JSONValidator.schema do
        field "name", required: true, type: "string"
        field "age", required: true, type: "int"
      end

      # Valid data
      valid_json = JSON.parse(%{{"name": "Alice", "age": 30}})
      result = schema.validate(valid_json)
      result.success?.should be_true

      # Missing required field
      invalid_json = JSON.parse(%{{"name": "Bob"}})
      result = schema.validate(invalid_json)
      result.failure?.should be_true
      result.errors.should contain("Required field 'age' is missing")
    end

    it "validates field types" do
      schema = Micro::Stdlib::JSONValidator.schema do
        field "name", type: "string"
        field "age", type: "int"
        field "active", type: "bool"
      end

      # Wrong type
      json = JSON.parse(%{{"name": 123, "age": "not a number", "active": "yes"}})
      result = schema.validate(json)
      result.failure?.should be_true
      result.errors.should contain("Field 'name' expected type 'string', got 'int'")
      result.errors.should contain("Field 'age' expected type 'int', got 'string'")
      result.errors.should contain("Field 'active' expected type 'bool', got 'string'")
    end

    it "validates string length constraints" do
      schema = Micro::Stdlib::JSONValidator.schema do
        field "username", min_length: 3, max_length: 20
        field "password", min_length: 8
      end

      # Too short
      json = JSON.parse(%{{"username": "ab", "password": "short"}})
      result = schema.validate(json)
      result.failure?.should be_true
      result.errors.should contain("Field 'username' must be at least 3 characters")
      result.errors.should contain("Field 'password' must be at least 8 characters")

      # Too long
      json = JSON.parse(%{{"username": "this_is_way_too_long_for_a_username"}})
      result = schema.validate(json)
      result.failure?.should be_true
      result.errors.should contain("Field 'username' must be at most 20 characters")
    end

    it "validates numeric ranges" do
      schema = Micro::Stdlib::JSONValidator.schema do
        field "age", type: "int", min: 0.0, max: 150.0
        field "score", type: "number", min: 0.0, max: 100.0
      end

      # Out of range
      json = JSON.parse(%{{"age": -5, "score": 150.5}})
      result = schema.validate(json)
      result.failure?.should be_true
      result.errors.should contain("Field 'age' must be at least 0.0")
      result.errors.should contain("Field 'score' must be at most 100.0")
    end

    it "validates pattern matching" do
      schema = Micro::Stdlib::JSONValidator.schema do
        field "email", pattern: /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/
        field "phone", pattern: /^\d{3}-\d{3}-\d{4}$/
      end

      # Invalid patterns
      json = JSON.parse(%{{"email": "not-an-email", "phone": "123456"}})
      result = schema.validate(json)
      result.failure?.should be_true
      result.errors.should contain("Field 'email' does not match required pattern")
      result.errors.should contain("Field 'phone' does not match required pattern")

      # Valid patterns
      json = JSON.parse(%{{"email": "user@example.com", "phone": "555-123-4567"}})
      result = schema.validate(json)
      result.success?.should be_true
    end

    it "validates enum values" do
      schema = Micro::Stdlib::JSONValidator.schema do
        field "status", enum: [
          JSON::Any.new("pending"),
          JSON::Any.new("active"),
          JSON::Any.new("completed"),
        ]
      end

      # Invalid enum value
      json = JSON.parse(%{{"status": "invalid"}})
      result = schema.validate(json)
      result.failure?.should be_true
      result.errors.should contain("Field 'status' must be one of: pending, active, completed")

      # Valid enum value
      json = JSON.parse(%{{"status": "active"}})
      result = schema.validate(json)
      result.success?.should be_true
    end

    it "supports custom validation" do
      schema = Micro::Stdlib::JSONValidator.schema do
        field "password", custom: ->(value : JSON::Any) {
          if str = value.as_s?
            # Password must contain at least one digit and one letter
            str.matches?(/\d/) && str.matches?(/[a-zA-Z]/)
          else
            false
          end
        }
      end

      # Fails custom validation
      json = JSON.parse(%{{"password": "onlyletters"}})
      result = schema.validate(json)
      result.failure?.should be_true
      result.errors.should contain("Field 'password' failed custom validation")

      # Passes custom validation
      json = JSON.parse(%{{"password": "password123"}})
      result = schema.validate(json)
      result.success?.should be_true
    end

    it "handles extra fields based on configuration" do
      # Strict schema (no extra fields)
      strict_schema = Micro::Stdlib::JSONValidator.schema(allow_extra_fields: false) do
        field "name", required: true
      end

      json = JSON.parse(%{{"name": "test", "extra": "field"}})
      result = strict_schema.validate(json)
      result.failure?.should be_true
      result.errors.should contain("Unexpected field 'extra'")

      # Permissive schema (allows extra fields)
      permissive_schema = Micro::Stdlib::JSONValidator.schema(allow_extra_fields: true) do
        field "name", required: true
      end

      result = permissive_schema.validate(json)
      result.success?.should be_true
    end
  end

  describe ".parse_and_validate" do
    it "combines parsing and validation" do
      schema = Micro::Stdlib::JSONValidator.schema do
        field "name", required: true, type: "string"
        field "age", required: true, type: "int", min: 0.0
      end

      # Valid JSON and schema
      result = Micro::Stdlib::JSONValidator.parse_and_validate(
        %{{"name": "Alice", "age": 25}},
        schema
      )
      result.success?.should be_true

      # Invalid JSON
      result = Micro::Stdlib::JSONValidator.parse_and_validate(
        %{invalid json},
        schema
      )
      result.failure?.should be_true
      result.errors.first.should contain("JSON parse error")

      # Valid JSON, invalid schema
      result = Micro::Stdlib::JSONValidator.parse_and_validate(
        %{{"name": "Bob"}},
        schema
      )
      result.failure?.should be_true
      result.errors.should contain("Required field 'age' is missing")
    end
  end

  describe ".parse_as" do
    it "parses into specific types" do
      user = Micro::Stdlib::JSONValidator.parse_as(JSONTestUser, %{{"name": "Alice", "age": 30}})
      user.should_not be_nil
      if u = user
        u.name.should eq("Alice")
        u.age.should eq(30)
      end
    end

    it "returns nil for invalid data" do
      user = Micro::Stdlib::JSONValidator.parse_as(JSONTestUser, %{{"invalid": "data"}})
      user.should be_nil
    end

    it "returns nil for parse errors" do
      user = Micro::Stdlib::JSONValidator.parse_as(JSONTestUser, %{not json})
      user.should be_nil
    end
  end

  describe ".parse_with_default" do
    it "returns parsed data on success" do
      default = JSON::Any.new({"error" => JSON::Any.new("default")})
      result = Micro::Stdlib::JSONValidator.parse_with_default(
        %{{"success": true}},
        default
      )
      result["success"].as_bool.should be_true
    end

    it "returns default on parse error" do
      default = JSON::Any.new({"error" => JSON::Any.new("default")})
      result = Micro::Stdlib::JSONValidator.parse_with_default(
        %{invalid json},
        default
      )
      result["error"].as_s.should eq("default")
    end
  end
end
