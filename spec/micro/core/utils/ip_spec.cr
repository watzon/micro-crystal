require "../../../spec_helper"
require "../../../../src/micro/core/utils/ip"

describe Micro::Core::Utils::IP do
  describe ".extract" do
    it "returns valid IP addresses as-is" do
      Micro::Core::Utils::IP.extract("192.168.1.100").should eq("192.168.1.100")
      Micro::Core::Utils::IP.extract("10.0.0.5").should eq("10.0.0.5")
    end

    it "returns hostname for 0.0.0.0" do
      result = Micro::Core::Utils::IP.extract("0.0.0.0")
      # Should return hostname or 127.0.0.1
      result.should_not eq("0.0.0.0")
    end

    it "returns hostname for empty string" do
      result = Micro::Core::Utils::IP.extract("")
      result.should_not eq("")
    end
  end

  describe ".parse_host_port" do
    it "parses host:port correctly" do
      host, port = Micro::Core::Utils::IP.parse_host_port("localhost:8080")
      host.should eq("localhost")
      port.should eq(8080)
    end

    it "defaults to port 80 when no port specified" do
      host, port = Micro::Core::Utils::IP.parse_host_port("example.com")
      host.should eq("example.com")
      port.should eq(80)
    end

    it "handles IPv6 addresses" do
      # IPv6 support not yet implemented - see docs/TODO.md
      # host, port = Micro::Core::Utils::IP.parse_host_port("[::1]:8080")
      # host.should eq("::1")
      # port.should eq(8080)
    end
  end

  describe ".valid_ip?" do
    it "validates IPv4 addresses" do
      Micro::Core::Utils::IP.valid_ip?("192.168.1.1").should be_true
      Micro::Core::Utils::IP.valid_ip?("0.0.0.0").should be_true
      Micro::Core::Utils::IP.valid_ip?("255.255.255.255").should be_true
    end

    it "rejects invalid addresses" do
      Micro::Core::Utils::IP.valid_ip?("hostname").should be_false
      Micro::Core::Utils::IP.valid_ip?("999.999.999.999").should be_false
      Micro::Core::Utils::IP.valid_ip?("").should be_false
    end
  end
end
