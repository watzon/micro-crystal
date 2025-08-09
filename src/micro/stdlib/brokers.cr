require "./brokers/nats"
require "./brokers/memory"

module Micro
  module Stdlib
    module Brokers
      # Factory method to create a broker by name
      def self.create(name : String, options : Core::Broker::Options = Core::Broker::Options.new) : Core::Broker::Base
        case name.downcase
        when "nats"
          NATSBroker.new(options)
        when "memory"
          MemoryBroker.new(options)
        else
          raise ArgumentError.new("Unknown broker: #{name}")
        end
      end
    end
  end
end
