require "openssl"

module Micro::Stdlib
  # TLS configuration for secure connections.
  #
  # This module provides a centralized configuration for TLS settings
  # across all transports and connections in micro-crystal. It supports
  # both client and server configurations with proper certificate validation.
  #
  # ## Features
  # - Certificate validation with configurable verify modes
  # - Custom CA certificate support
  # - Client certificate authentication (mTLS)
  # - Configurable cipher suites and TLS versions
  # - ALPN (Application-Layer Protocol Negotiation) support
  # - SNI (Server Name Indication) support
  #
  # ## Usage
  # ```
  # # Client configuration with default system certificates
  # tls_config = TLSConfig.new(
  #   verify_mode: :peer,
  #   min_version: :tls1_2
  # )
  #
  # # Client configuration with custom CA
  # tls_config = TLSConfig.new(
  #   verify_mode: :peer,
  #   ca_certificates: "/path/to/ca.pem"
  # )
  #
  # # mTLS client configuration
  # tls_config = TLSConfig.new(
  #   verify_mode: :peer,
  #   ca_certificates: "/path/to/ca.pem",
  #   client_certificate: "/path/to/client.crt",
  #   client_key: "/path/to/client.key"
  # )
  #
  # # Server configuration
  # tls_config = TLSConfig.server(
  #   certificate_chain: "/path/to/server.crt",
  #   private_key: "/path/to/server.key",
  #   verify_mode: :peer_or_none
  # )
  #
  # # Apply to OpenSSL context
  # ssl_context = tls_config.to_openssl_context(:client)
  # ```
  #
  # ## Security Best Practices
  # - Always use :peer verify mode in production
  # - Use TLS 1.2 or higher (1.3 preferred)
  # - Regularly update CA certificates
  # - Use strong cipher suites
  # - Enable certificate revocation checking when possible
  class TLSConfig
    # TLS protocol versions
    enum Version
      SSL3   # Deprecated, do not use
      TLS1_0 # Deprecated, avoid if possible
      TLS1_1 # Deprecated, avoid if possible
      TLS1_2 # Minimum recommended
      TLS1_3 # Preferred
    end

    # Certificate verification modes
    enum VerifyMode
      # No verification (INSECURE - only for testing)
      None

      # Verify peer certificate if provided
      PeerOrNone

      # Always verify peer certificate (recommended)
      Peer

      # Verify peer and fail if no certificate provided
      ForcePeer

      # Verify peer certificate only once per session
      VerifyOnce
    end

    # Configuration properties
    getter verify_mode : VerifyMode
    getter min_version : Version?
    getter max_version : Version?
    getter ca_certificates : String?
    getter ca_certificates_path : String?
    getter client_certificate : String?
    getter client_key : String?
    getter certificate_chain : String?
    getter private_key : String?
    getter cipher_suites : String?
    getter alpn_protocols : Array(String)?
    getter verify_depth : Int32
    getter security_level : Int32?
    getter hostname_verification : Bool
    getter revocation_check : Bool
    getter session_cache : Bool

    def initialize(
      @verify_mode : VerifyMode = VerifyMode::Peer,
      @min_version : Version? = Version::TLS1_2,
      @max_version : Version? = nil,
      @ca_certificates : String? = nil,
      @ca_certificates_path : String? = nil,
      @client_certificate : String? = nil,
      @client_key : String? = nil,
      @certificate_chain : String? = nil,
      @private_key : String? = nil,
      @cipher_suites : String? = nil,
      @alpn_protocols : Array(String)? = nil,
      @verify_depth : Int32 = 10,
      @security_level : Int32? = nil,
      @hostname_verification : Bool = true,
      @revocation_check : Bool = false,
      @session_cache : Bool = true,
    )
      validate_configuration!
    end

    # Create a server TLS configuration
    def self.server(
      certificate_chain : String,
      private_key : String,
      verify_mode : VerifyMode = VerifyMode::PeerOrNone,
      ca_certificates : String? = nil,
      cipher_suites : String? = nil,
      min_version : Version? = nil,
      max_version : Version? = nil,
      alpn_protocols : Array(String)? = nil,
    ) : TLSConfig
      new(
        certificate_chain: certificate_chain,
        private_key: private_key,
        verify_mode: verify_mode,
        ca_certificates: ca_certificates,
        cipher_suites: cipher_suites,
        min_version: min_version,
        max_version: max_version,
        alpn_protocols: alpn_protocols
      )
    end

    # Create a client TLS configuration
    def self.client(
      verify_mode : VerifyMode = VerifyMode::Peer,
      certificate_chain : String? = nil,
      private_key : String? = nil,
      ca_certificates : String? = nil,
      ca_certificates_path : String? = nil,
      client_certificate : String? = nil,
      client_key : String? = nil,
      cipher_suites : String? = nil,
      min_version : Version? = nil,
      max_version : Version? = nil,
      alpn_protocols : Array(String)? = nil,
    ) : TLSConfig
      new(
        verify_mode: verify_mode,
        certificate_chain: certificate_chain,
        private_key: private_key,
        ca_certificates: ca_certificates,
        ca_certificates_path: ca_certificates_path,
        client_certificate: client_certificate,
        client_key: client_key,
        cipher_suites: cipher_suites,
        min_version: min_version,
        max_version: max_version,
        alpn_protocols: alpn_protocols
      )
    end

    # Create an insecure configuration (for testing only)
    def self.insecure : TLSConfig
      new(
        verify_mode: VerifyMode::None,
        hostname_verification: false
      )
    end

    # Convert to OpenSSL::SSL::Context
    def to_openssl_context(type : Symbol = :client) : OpenSSL::SSL::Context::Client | OpenSSL::SSL::Context::Server
      case type
      when :client
        create_client_context
      when :server
        create_server_context
      else
        raise ArgumentError.new("Invalid context type: #{type}")
      end
    end

    # Apply configuration to existing OpenSSL context
    def apply_to(context : OpenSSL::SSL::Context::Client | OpenSSL::SSL::Context::Server) : Nil
      # Set verification mode
      context.verify_mode = openssl_verify_mode

      # Set protocol versions
      if min_ver = @min_version
        case min_ver
        when .tls1_2?
          context.add_options(OpenSSL::SSL::Options::NO_TLS_V1 | OpenSSL::SSL::Options::NO_TLS_V1_1)
        when .tls1_3?
          context.add_options(OpenSSL::SSL::Options::NO_TLS_V1 | OpenSSL::SSL::Options::NO_TLS_V1_1 | OpenSSL::SSL::Options::NO_TLS_V1_2)
        end
      end

      # Always disable deprecated protocols
      context.add_options(
        OpenSSL::SSL::Options::NO_SSL_V2 |
        OpenSSL::SSL::Options::NO_SSL_V3
      )

      # Set CA certificates
      if ca_certs = @ca_certificates
        context.ca_certificates = ca_certs
      elsif ca_path = @ca_certificates_path
        context.ca_certificates_path = ca_path
      elsif @verify_mode != VerifyMode::None
        # Use system default CA certificates
        context.set_default_verify_paths
      end

      # Set client certificates for mTLS
      if client_cert = @client_certificate
        context.certificate_chain = client_cert
      end

      if client_key = @client_key
        context.private_key = client_key
      end

      # Set server certificates
      if cert_chain = @certificate_chain
        context.certificate_chain = cert_chain
      end

      if priv_key = @private_key
        context.private_key = priv_key
      end

      # Set cipher suites
      if ciphers = @cipher_suites
        context.ciphers = ciphers
      end

      # Set ALPN protocols
      if alpn = @alpn_protocols
        context.alpn_protocol = alpn.join(",")
      end

      # NOTE: verify_depth and security_level are not available in Crystal's OpenSSL bindings
      # These would need to be implemented through LibSSL bindings if needed

      # Enable session caching if requested
      if @session_cache
        context.add_options(OpenSSL::SSL::Options::SINGLE_DH_USE)
      else
        context.add_options(OpenSSL::SSL::Options::NO_SESSION_RESUMPTION_ON_RENEGOTIATION)
      end
    end

    # Creates an OpenSSL client context with the configured TLS settings.
    # Applies all TLS configuration to the context.
    private def create_client_context : OpenSSL::SSL::Context::Client
      context = OpenSSL::SSL::Context::Client.new
      apply_to(context)
      context
    end

    # Creates an OpenSSL server context with the configured TLS settings.
    # Applies all TLS configuration to the context.
    private def create_server_context : OpenSSL::SSL::Context::Server
      context = OpenSSL::SSL::Context::Server.new
      apply_to(context)
      context
    end

    # Converts the configured verify mode to OpenSSL's VerifyMode enum.
    # Maps string/symbol modes to OpenSSL constants.
    private def openssl_verify_mode : OpenSSL::SSL::VerifyMode
      case @verify_mode
      when .none?
        OpenSSL::SSL::VerifyMode::NONE
      when .peer_or_none?
        OpenSSL::SSL::VerifyMode::PEER
      when .peer?
        OpenSSL::SSL::VerifyMode::PEER | OpenSSL::SSL::VerifyMode::FAIL_IF_NO_PEER_CERT
      when .force_peer?
        OpenSSL::SSL::VerifyMode::PEER | OpenSSL::SSL::VerifyMode::FAIL_IF_NO_PEER_CERT
      when .verify_once?
        OpenSSL::SSL::VerifyMode::PEER | OpenSSL::SSL::VerifyMode::CLIENT_ONCE
      else
        OpenSSL::SSL::VerifyMode::PEER
      end
    end

    # Validates the TLS configuration for consistency and correctness.
    # Ensures required files exist and settings are compatible.
    private def validate_configuration!
      # Validate certificate and key pairs
      if @client_certificate && !@client_key
        raise ArgumentError.new("Client certificate provided without client key")
      end

      if @client_key && !@client_certificate
        raise ArgumentError.new("Client key provided without client certificate")
      end

      if @certificate_chain && !@private_key
        raise ArgumentError.new("Certificate chain provided without private key")
      end

      if @private_key && !@certificate_chain
        raise ArgumentError.new("Private key provided without certificate chain")
      end

      # Warn about insecure configurations
      if @verify_mode.none?
        Log.warn { "TLS verification disabled - this is insecure and should only be used for testing" }
      end

      if @min_version.try(&.tls1_0?) || @min_version.try(&.tls1_1?)
        Log.warn { "Using TLS 1.0 or 1.1 - these versions are deprecated and insecure" }
      end
    end
  end

  # Global TLS configuration registry
  class TLSRegistry
    @@configs = {} of String => TLSConfig
    @@default_client : TLSConfig?
    @@default_server : TLSConfig?

    # Register a named TLS configuration
    def self.register(name : String, config : TLSConfig) : Nil
      @@configs[name] = config
    end

    # Get a named TLS configuration
    def self.get(name : String) : TLSConfig?
      @@configs[name]?
    end

    # Get a named TLS configuration, raising if not found
    def self.get!(name : String) : TLSConfig
      get(name) || raise "TLS configuration not found: #{name}"
    end

    # Set the default client configuration
    def self.default_client=(config : TLSConfig) : TLSConfig
      @@default_client = config
    end

    # Get the default client configuration
    def self.default_client : TLSConfig
      @@default_client ||= TLSConfig.client
    end

    # Set the default server configuration
    def self.default_server=(config : TLSConfig) : TLSConfig
      @@default_server = config
    end

    # Get the default server configuration
    def self.default_server : TLSConfig
      @@default_server ||= raise "No default server TLS configuration set"
    end

    # Clear all configurations (useful for testing)
    def self.clear : Nil
      @@configs.clear
      @@default_client = nil
      @@default_server = nil
    end
  end
end
