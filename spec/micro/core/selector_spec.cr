require "../../spec_helper"

# Helper module for selector tests
module SelectorTestHelpers
  def self.create_nodes(count : Int32) : Array(Micro::Core::Registry::Node)
    (1..count).map do |i|
      Micro::Core::Registry::Node.new(
        id: "node-#{i}",
        address: "192.168.1.#{i}",
        port: 8080 + i,
        metadata: {"zone" => "zone-#{i}"}
      )
    end.to_a
  end
end

describe Micro::Core::Selector do
  describe Micro::Core::RandomSelector do
    describe "#select" do
      it "selects a node from available nodes" do
        selector = Micro::Core::RandomSelector.new
        nodes = SelectorTestHelpers.create_nodes(3)

        selected = selector.select(nodes)
        nodes.should contain(selected)
      end

      it "raises error when no nodes available" do
        selector = Micro::Core::RandomSelector.new
        nodes = [] of Micro::Core::Registry::Node

        expect_raises(ArgumentError, "No nodes available") do
          selector.select(nodes)
        end
      end

      it "can select different nodes (randomness test)" do
        selector = Micro::Core::RandomSelector.new
        nodes = SelectorTestHelpers.create_nodes(10)

        # Select many times and verify we get different nodes
        selections = (1..100).map { selector.select(nodes) }
        unique_selections = selections.uniq

        # With 10 nodes and 100 selections, we should get multiple different nodes
        # This test might theoretically fail with extremely bad luck, but probability is negligible
        unique_selections.size.should be > 1
      end

      it "works with single node" do
        selector = Micro::Core::RandomSelector.new
        nodes = SelectorTestHelpers.create_nodes(1)

        # Should always return the same node
        100.times do
          selector.select(nodes).should eq(nodes.first)
        end
      end
    end

    describe "#reset" do
      it "can be called without error" do
        selector = Micro::Core::RandomSelector.new
        selector.reset # Should not raise
      end
    end
  end

  describe Micro::Core::RoundRobinSelector do
    describe "#select" do
      it "cycles through nodes in order" do
        selector = Micro::Core::RoundRobinSelector.new
        nodes = SelectorTestHelpers.create_nodes(3)

        # First round
        selector.select(nodes).id.should eq("node-1")
        selector.select(nodes).id.should eq("node-2")
        selector.select(nodes).id.should eq("node-3")

        # Second round - should cycle back
        selector.select(nodes).id.should eq("node-1")
        selector.select(nodes).id.should eq("node-2")
        selector.select(nodes).id.should eq("node-3")
      end

      it "raises error when no nodes available" do
        selector = Micro::Core::RoundRobinSelector.new
        nodes = [] of Micro::Core::Registry::Node

        expect_raises(ArgumentError, "No nodes available") do
          selector.select(nodes)
        end
      end

      it "handles single node correctly" do
        selector = Micro::Core::RoundRobinSelector.new
        nodes = SelectorTestHelpers.create_nodes(1)

        # Should always return the same node
        5.times do
          selector.select(nodes).should eq(nodes.first)
        end
      end

      it "handles node list changes gracefully" do
        selector = Micro::Core::RoundRobinSelector.new

        # Start with 3 nodes
        nodes = SelectorTestHelpers.create_nodes(3)
        selector.select(nodes).id.should eq("node-1")
        selector.select(nodes).id.should eq("node-2")

        # Reduce to 2 nodes
        nodes = SelectorTestHelpers.create_nodes(2)
        selector.select(nodes).id.should eq("node-1") # Index 2 % 2 = 0
        selector.select(nodes).id.should eq("node-2") # Index 3 % 2 = 1

        # Increase to 5 nodes
        nodes = SelectorTestHelpers.create_nodes(5)
        selector.select(nodes).id.should eq("node-5") # Index 4 % 5 = 4
        selector.select(nodes).id.should eq("node-1") # Index 5 % 5 = 0
      end

      it "is thread-safe" do
        selector = Micro::Core::RoundRobinSelector.new
        nodes = SelectorTestHelpers.create_nodes(10)
        results = [] of String
        mutex = Mutex.new

        # Spawn multiple fibers to select concurrently
        (1..10).each do
          spawn do
            10.times do
              node = selector.select(nodes)
              mutex.synchronize { results << node.id }
              Fiber.yield
            end
          end
        end

        # Wait for all fibers to complete
        sleep 0.15.seconds

        # Should have exactly 100 selections
        results.size.should eq(100)

        # Count occurrences of each node
        counts = Hash(String, Int32).new(0)
        results.each { |id| counts[id] += 1 }

        # Each node should be selected exactly 10 times (100 selections / 10 nodes)
        counts.each_value(&.should(eq(10)))
      end
    end

    describe "#reset" do
      it "resets the index to start from beginning" do
        selector = Micro::Core::RoundRobinSelector.new
        nodes = SelectorTestHelpers.create_nodes(3)

        # Select a few times
        selector.select(nodes).id.should eq("node-1")
        selector.select(nodes).id.should eq("node-2")

        # Reset
        selector.reset

        # Should start from beginning again
        selector.select(nodes).id.should eq("node-1")
        selector.select(nodes).id.should eq("node-2")
        selector.select(nodes).id.should eq("node-3")
      end

      it "is thread-safe" do
        selector = Micro::Core::RoundRobinSelector.new
        nodes = SelectorTestHelpers.create_nodes(5)

        # Select a few times to advance index
        3.times { selector.select(nodes) }

        # Reset from multiple fibers simultaneously
        5.times do
          spawn { selector.reset }
        end

        sleep 0.01.seconds

        # After reset, should start from beginning
        selector.select(nodes).id.should eq("node-1")
      end
    end
  end

  describe "Selector interface compliance" do
    it "all selectors implement required methods" do
      selectors = [
        Micro::Core::RandomSelector.new,
        Micro::Core::RoundRobinSelector.new,
      ]

      nodes = SelectorTestHelpers.create_nodes(3)

      selectors.each do |selector|
        # Should be able to call select
        selector.should be_a(Micro::Core::Selector)
        selected = selector.select(nodes)
        selected.should be_a(Micro::Core::Registry::Node)

        # Should be able to call reset
        selector.reset
      end
    end
  end

  describe "Edge cases" do
    it "handles very large node lists" do
      # Test with 1000 nodes
      nodes = SelectorTestHelpers.create_nodes(1000)

      random_selector = Micro::Core::RandomSelector.new
      round_robin_selector = Micro::Core::RoundRobinSelector.new

      # Both should handle large lists without issues
      100.times do
        random_node = random_selector.select(nodes)
        nodes.should contain(random_node)

        rr_node = round_robin_selector.select(nodes)
        nodes.should contain(rr_node)
      end
    end

    it "selectors work with nodes having same addresses but different ports" do
      nodes = [
        Micro::Core::Registry::Node.new("node-1", "192.168.1.1", 8080),
        Micro::Core::Registry::Node.new("node-2", "192.168.1.1", 8081),
        Micro::Core::Registry::Node.new("node-3", "192.168.1.1", 8082),
      ]

      selector = Micro::Core::RoundRobinSelector.new

      # Should cycle through all nodes even with same address
      selector.select(nodes).port.should eq(8080)
      selector.select(nodes).port.should eq(8081)
      selector.select(nodes).port.should eq(8082)
      selector.select(nodes).port.should eq(8080)
    end
  end
end
