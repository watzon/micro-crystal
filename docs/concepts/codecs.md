# Codecs

## Table of contents

- [Key concepts](#key-concepts)
- [Available codecs](#available-codecs)
- [Using codecs with services](#using-codecs-with-services)
- [Content negotiation](#content-negotiation)
- [Custom codecs](#custom-codecs)
- [Codec selection](#codec-selection)
- [Performance comparison](#performance-comparison)
- [Working with binary data](#working-with-binary-data)
- [Error handling](#error-handling)
- [Streaming support](#streaming-support)
- [Best practices](#best-practices)

Codecs handle serialization and deserialization of data sent between services. They define how Crystal objects are encoded for transport and decoded back into typed objects.

## Key concepts

### Codec interface
All codecs implement the `Micro::Core::Codec` interface with methods for encoding and decoding data. This allows different serialization formats to be used interchangeably.

### Content types
Each codec has an associated content type (MIME type) that identifies the encoding format in transport headers. This enables automatic codec selection based on client preferences.

### Type safety
Codecs work with Crystal's type system to ensure compile-time safety when encoding and decoding messages.

## Available codecs

### JSON codec

The default codec using Crystal's built-in JSON support:

```crystal
codec = Micro::Codecs.json

# Configure service to use JSON
service_options = Micro::ServiceOptions.new(
  name: "api",
  version: "1.0.0",
  codec: codec,
  server_options: Micro::Core::ServerOptions.new(
    address: "0.0.0.0:8080"
  )
)
```

JSON codec characteristics:
- Human-readable format
- Wide language support
- Excellent debugging
- Larger payload size

### MessagePack codec

For efficient binary encoding:

```crystal
codec = Micro::Codecs.msgpack

# 2-4x smaller than JSON for typical payloads
service_options = Micro::ServiceOptions.new(
  name: "api",
  version: "1.0.0",
  codec: codec,
  server_options: Micro::Core::ServerOptions.new(
    address: "0.0.0.0:8080"
  )
)
```

MessagePack codec characteristics:
- Compact binary format
- Faster encoding/decoding
- Smaller network payloads
- Not human-readable

## Using codecs with services

### Request and response types

Define serializable types for your service methods:

```crystal
# Types must include serialization modules
struct CreateUserRequest
  include JSON::Serializable
  include MessagePack::Serializable
  
  getter name : String
  getter email : String
  getter age : Int32?
end

struct CreateUserResponse
  include JSON::Serializable
  include MessagePack::Serializable
  
  getter id : String
  getter created_at : Time
end

@[Micro::Service(name: "users")]
class UserService
  include Micro::ServiceBase
  
  @[Micro::Method]
  def create_user(ctx : Micro::Core::Context, req : CreateUserRequest) : CreateUserResponse
    # Codec automatically handles serialization
    CreateUserResponse.new(
      id: UUID.random.to_s,
      created_at: Time.utc
    )
  end
end
```

### Content negotiation

Services automatically support content negotiation via Accept headers:

```crystal
# Register codecs globally
Micro.register_codec(Micro::Codecs.json)
Micro.register_codec(Micro::Codecs.msgpack)

# Services automatically negotiate based on Accept header
# Client: Accept: application/msgpack
# Server: Content-Type: application/msgpack

## Custom codecs

Implement custom codecs for specific formats:

```crystal
class ProtobufCodec < Micro::Core::Codec
  def content_type : String
    "application/x-protobuf"
  end
  
  def name : String
    "protobuf"
  end
  
  def extension : String
    "pb"
  end
  
  def marshal(obj : Object) : Bytes
    # Encode using protobuf library
    obj.to_protobuf.to_slice
  end
  
  def unmarshal(data : Bytes, type : T.class) : T forall T
    # Decode using protobuf library
    T.from_protobuf(data)
  end
  
  def unmarshal?(data : Bytes, type : T.class) : T? forall T
    unmarshal(data, type)
  rescue
    nil
  end
end

# Register and use custom codec
Micro.register_codec(ProtobufCodec.new)

service_options = Micro::ServiceOptions.new(
  name: "api",
  version: "1.0.0",
  codec: ProtobufCodec.new
)
```

## Codec selection

Choose codecs based on your requirements:

### Use JSON when:
- Human readability is important
- Debugging is a priority
- Interoperating with web clients
- Payload size isn't critical

### Use MessagePack when:
- Performance is critical
- Network bandwidth is limited
- Services are internal-only
- Binary data is common

### Use custom codecs when:
- Specific format requirements exist
- Legacy system compatibility needed
- Domain-specific optimizations required

## Performance comparison

Typical performance characteristics for a 1KB payload:

```crystal
# Typical performance characteristics:
# JSON: Human-readable, good compatibility, larger size
# MessagePack: Binary format, faster, smaller size

# Size comparison for typical payloads:
# JSON: ~150-200 bytes for small objects
# MessagePack: ~100-150 bytes (20-30% smaller)

# Performance comparison:
# MessagePack is typically 1.5-2x faster for encoding/decoding
```

## Working with binary data

Handle binary data appropriately for each codec:

```crystal
struct FileUpload
  include JSON::Serializable
  include MessagePack::Serializable
  
  getter filename : String
  @[JSON::Field(converter: Base64Converter)]
  @[MessagePack::Field(as_bytes: true)]
  getter content : Bytes
end

# Base64 converter for JSON
module Base64Converter
  def self.to_json(value : Bytes, json : JSON::Builder)
    json.string(Base64.encode(value))
  end
  
  def self.from_json(parser : JSON::PullParser) : Bytes
    Base64.decode(parser.read_string)
  end
end
```

## Error handling

Codecs should handle encoding/decoding errors gracefully:

```crystal
begin
  response = client.call("service", "method", invalid_data)
rescue ex : Micro::Core::CodecError
  Log.error { "Codec error: #{ex.message}" }
  
  # Fall back or return error
  return ErrorResponse.new(
    error: "Invalid data format",
    details: ex.message
  )
end
```

## Streaming support

For large payloads, codecs work with streaming transports:

```crystal
# Streaming is handled at the transport level
# Codecs marshal/unmarshal individual messages in the stream

@[Micro::Handler(streaming: true)]
def export_data(ctx : Micro::Core::Context, req : ExportRequest) : ExportResponse
  # Each response is encoded separately by the codec
  ctx.stream do |stream|
    database.each_row do |row|
      stream.send(row)  # Codec marshals each row
    end
  end
end
```

## Best practices

### Include all serialization modules
Always include modules for all codecs your service supports:

```crystal
struct MyRequest
  include JSON::Serializable
  include MessagePack::Serializable
  # Include others as needed
  
  getter field : String
end
```

### Use appropriate data types
Some types serialize better than others:
- Use `Time` instead of string timestamps
- Use `UUID` for identifiers
- Use `Bytes` for binary data
- Never use `Symbol` in serialized data (not supported)

### Validate decoded data
Don't trust decoded data implicitly:

```crystal
@[Micro::Method]
def process(ctx : Micro::Core::Context, req : Request) : Response
  # Validate after decoding
  unless req.valid?
    raise Micro::Core::Error.new(
      code: 400,
      detail: "Invalid request: #{req.errors}"
    )
  end
  
  # Process valid request
  Response.new(status: "ok")
end
```

## Related concepts

- [Services](services.md) - How services use codecs
- [Transport](transport.md) - How codecs integrate with transport
- [Context](context.md) - Content-type negotiation
- [Broker](broker.md) - Event encoding with codecs