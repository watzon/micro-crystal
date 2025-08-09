require "../../spec_helper"

# Mock implementation of Stream for testing
class MockStream < Micro::Core::Stream
  getter sent_messages = [] of Bytes
  getter? closed = false
  getter? send_closed = false
  property receive_queue = [] of Bytes

  def send(body : Bytes) : Nil
    raise "Stream is closed" if @closed || @send_closed
    @sent_messages << body
  end

  def receive : Bytes
    raise "Stream is closed" if @closed
    until msg = @receive_queue.shift?
      sleep 0.001.seconds
    end
    msg
  end

  def receive(timeout : Time::Span) : Bytes?
    raise "Stream is closed" if @closed
    deadline = Time.monotonic + timeout

    loop do
      return @receive_queue.shift? if !@receive_queue.empty?
      return nil if Time.monotonic >= deadline
      sleep 0.001.seconds
    end
  end

  def close : Nil
    @closed = true
    @send_closed = true
  end

  def closed? : Bool
    @closed
  end

  def close_send : Nil
    @send_closed = true
  end

  def send_closed? : Bool
    @send_closed
  end

  # Test helper to simulate receiving a message
  def simulate_receive(data : Bytes)
    @receive_queue << data
  end
end

# Mock StreamHandler for testing
class MockStreamHandler < Micro::Core::StreamHandler
  getter handled_streams = [] of String
  getter errors = [] of {String, String}
  getter closed_streams = [] of String

  def handle(stream : Micro::Core::Stream, request : Micro::Core::TransportRequest) : Nil
    @handled_streams << stream.id

    # Simple echo behavior for testing
    loop do
      if data = stream.receive(1.second)
        stream.send(data)
      else
        break
      end
    end
  end

  def on_error(stream : Micro::Core::Stream, error : Exception) : Nil
    @errors << {stream.id, error.message || ""}
  end

  def on_close(stream : Micro::Core::Stream) : Nil
    @closed_streams << stream.id
  end
end

describe Micro::Core::Stream do
  describe "base functionality" do
    it "has unique ID" do
      stream1 = MockStream.new
      stream2 = MockStream.new

      stream1.id.should_not eq(stream2.id)
    end

    it "has metadata headers" do
      stream = MockStream.new
      stream.metadata.should be_a(HTTP::Headers)
      stream.metadata.should be_empty
    end

    it "can send and receive messages" do
      stream = MockStream.new

      # Simulate bidirectional communication
      message = "Hello, Stream!".to_slice
      stream.simulate_receive(message)

      received = stream.receive
      received.should eq(message)

      stream.send("Response".to_slice)
      stream.sent_messages.size.should eq(1)
      stream.sent_messages.first.should eq("Response".to_slice)
    end

    it "handles receive with timeout" do
      stream = MockStream.new

      # No message available
      result = stream.receive(0.1.seconds)
      result.should be_nil

      # Message becomes available
      stream.simulate_receive("Late message".to_slice)
      result = stream.receive(0.1.seconds)
      result.should_not be_nil
      result.should eq("Late message".to_slice)
    end

    it "can close stream" do
      stream = MockStream.new

      stream.closed?.should be_false
      stream.close
      stream.closed?.should be_true
      stream.send_closed?.should be_true
    end

    it "can close send side only" do
      stream = MockStream.new

      stream.send_closed?.should be_false
      stream.close_send
      stream.send_closed?.should be_true
      stream.closed?.should be_false

      # Can still receive
      stream.simulate_receive("Final message".to_slice)
      stream.receive.should eq("Final message".to_slice)
    end

    it "prevents send after close" do
      stream = MockStream.new
      stream.close

      expect_raises(Exception, "Stream is closed") do
        stream.send("Should fail".to_slice)
      end
    end

    it "can send with headers" do
      stream = MockStream.new

      stream.send("Data".to_slice, HTTP::Headers{"Content-Type" => "application/json", "X-Custom" => "value"})

      stream.metadata["Content-Type"].should eq("application/json")
      stream.metadata["X-Custom"].should eq("value")
      stream.sent_messages.first.should eq("Data".to_slice)
    end

    it "can send error" do
      stream = MockStream.new

      stream.send_error("Something went wrong")
      stream.metadata["error"].should eq("Something went wrong")
      stream.closed?.should be_true
    end
  end
end

describe Micro::Core::StreamHandler do
  it "handles stream lifecycle" do
    handler = MockStreamHandler.new
    stream = MockStream.new
    request = Micro::Core::TransportRequest.new(
      service: "test",
      method: "stream",
      body: Bytes.empty
    )

    # Simulate stream handling in a fiber
    spawn do
      handler.handle(stream, request)
    end

    # Give handler time to register
    sleep 0.01.seconds

    handler.handled_streams.should contain(stream.id)

    # Simulate error
    handler.on_error(stream, Exception.new("Test error"))
    handler.errors.should eq([{stream.id, "Test error"}])

    # Simulate close
    handler.on_close(stream)
    handler.closed_streams.should contain(stream.id)
  end
end
