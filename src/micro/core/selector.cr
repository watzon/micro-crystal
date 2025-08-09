module Micro::Core
  # Selector interface for choosing service nodes
  abstract class Selector
    # Select a node from the available nodes
    abstract def select(nodes : Array(Registry::Node)) : Registry::Node

    # Reset selector state (for strategies that maintain state)
    abstract def reset : Nil
  end

  # Random selector - randomly selects a node
  class RandomSelector < Selector
    def select(nodes : Array(Registry::Node)) : Registry::Node
      raise ArgumentError.new("No nodes available") if nodes.empty?
      nodes.sample
    end

    def reset : Nil
      # No state to reset
    end
  end

  # Round-robin selector - cycles through nodes
  class RoundRobinSelector < Selector
    @index = 0
    @mutex = Mutex.new

    def select(nodes : Array(Registry::Node)) : Registry::Node
      raise ArgumentError.new("No nodes available") if nodes.empty?

      @mutex.synchronize do
        node = nodes[@index % nodes.size]
        @index += 1
        node
      end
    end

    def reset : Nil
      @mutex.synchronize do
        @index = 0
      end
    end
  end
end
