require "./json/codec"

module Micro::Stdlib::Codecs::JSON
  # Convenience alias
  alias Codec = JSONCodec

  # Create a new JSON codec instance
  def self.new
    JSONCodec.new
  end

  # Get the registered JSON codec instance
  def self.instance
    Micro::Core::CodecRegistry.instance.get!("application/json").as(JSONCodec)
  end
end
