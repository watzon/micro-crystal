module Micro::Core::Utils
  # IP address utilities for service discovery
  module IP
    # Extract a usable IP address from the given host
    # If host is 0.0.0.0 or empty, tries to detect the best local IP
    def self.extract(host : String) : String
      # If it's a valid IP that's not 0.0.0.0, return it
      if host && host != "0.0.0.0" && host != ""
        return host
      end

      # Try to get hostname first
      hostname = System.hostname

      # Simple IP detection - returns hostname or localhost
      # For more sophisticated detection (network interfaces, Docker/K8s awareness),
      # see docs/TODO.md

      hostname.empty? ? "127.0.0.1" : hostname
    end

    # Check if the given string is a valid IP address
    def self.valid_ip?(addr : String) : Bool
      return false if addr.empty?

      # Check IPv4 format
      parts = addr.split(".")
      return false unless parts.size == 4

      parts.all? do |part|
        num = part.to_i?
        num && num >= 0 && num <= 255
      end
    end

    # Parse host:port combination
    def self.parse_host_port(address : String) : {String, Int32}
      parts = address.split(":", 2)
      host = parts[0]
      port = parts[1]?.try(&.to_i) || 80
      {host, port}
    end
  end
end
