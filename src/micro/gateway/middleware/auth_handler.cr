# Authentication middleware for API Gateway
require "http/server"
require "jwt"

module Micro::Gateway
  # HTTP Handler for JWT authentication
  class AuthHandler
    include HTTP::Handler

    Log = ::Log.for(self)

    getter config : AuthConfig
    getter skip_paths : Set(String)

    def initialize(@config : AuthConfig)
      @skip_paths = Set.new(@config.skip_paths)
    end

    def call(context : HTTP::Server::Context)
      # Skip auth for configured paths
      if should_skip?(context.request.path)
        call_next(context)
        return
      end

      # Extract token
      token = extract_token(context.request)

      unless token
        unauthorized(context.response, "Missing authentication token")
        return
      end

      # Verify token
      begin
        payload = verify_token(token)

        # Add claims to context for downstream handlers
        context.request.headers["X-User-ID"] = payload["sub"].as_s if payload["sub"]?
        context.request.headers["X-User-Roles"] = payload["roles"].as_a.join(",") if payload["roles"]?

        call_next(context)
      rescue JWT::DecodeError
        unauthorized(context.response, "Invalid token")
      rescue JWT::ExpiredSignatureError
        unauthorized(context.response, "Token expired")
      rescue ex
        Log.error(exception: ex) { "Authentication error" }
        unauthorized(context.response, "Authentication failed")
      end
    end

    private def should_skip?(path : String) : Bool
      @skip_paths.includes?(path) || @skip_paths.any? do |pattern|
        if pattern.includes?("*")
          # Simple wildcard matching
          regex_pattern = pattern.gsub("*", ".*")
          Regex.new("^#{regex_pattern}$").matches?(path)
        else
          false
        end
      end
    end

    private def extract_token(request : HTTP::Request) : String?
      # Try Authorization header first
      if auth_header = request.headers["Authorization"]?
        if auth_header.starts_with?("Bearer ")
          return auth_header[7..]
        end
      end

      # Try cookie
      if @config.cookie_name
        if cookie = request.cookies[@config.cookie_name]?
          return cookie.value
        end
      end

      # Try query parameter
      if @config.query_param
        if params = request.query_params
          return params[@config.query_param]?
        end
      end

      nil
    end

    private def verify_token(token : String) : JSON::Any
      JWT.decode(
        token,
        @config.public_key || @config.secret.not_nil!,
        @config.algorithm
      )[0]
    end

    private def unauthorized(response : HTTP::Server::Response, message : String)
      response.status_code = 401
      response.content_type = "application/json"
      response.headers["WWW-Authenticate"] = "Bearer realm=\"#{@config.realm}\""
      response.print({
        "error"   => "Unauthorized",
        "message" => message,
      }.to_json)
      response.close
    end
  end

  # Authentication configuration
  class AuthConfig
    property algorithm : JWT::Algorithm
    property secret : String?
    property public_key : String?
    property skip_paths : Array(String)
    property cookie_name : String?
    property query_param : String?
    property realm : String

    def initialize(
      @algorithm : JWT::Algorithm = JWT::Algorithm::HS256,
      @secret : String? = nil,
      @public_key : String? = nil,
      @skip_paths : Array(String) = [] of String,
      @cookie_name : String? = nil,
      @query_param : String? = nil,
      @realm : String = "API Gateway",
    )
      if @secret.nil? && @public_key.nil?
        raise ArgumentError.new("Either secret or public_key must be provided")
      end
    end
  end
end
