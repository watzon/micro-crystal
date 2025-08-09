require "./codecs/json"

module Micro::Stdlib::Codecs
  # Initialize all default codecs
  def self.init! : Nil
    # JSON codec is auto-registered when required
  end

  # Get the global codec registry
  def self.registry
    Micro::Core::CodecRegistry.instance
  end
end

# Ensure default codecs are initialized
Micro::Stdlib::Codecs.init!
