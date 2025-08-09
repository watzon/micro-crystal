# CORS middleware for API Gateway
require "http/server"

module Micro::Gateway
  # HTTP Handler for CORS support
  class CORSHandler
    include HTTP::Handler

    def initialize(@config : CORSConfig)
    end

    def call(context : HTTP::Server::Context)
      request = context.request
      response = context.response

      # Handle preflight requests
      if request.method == "OPTIONS"
        handle_preflight(request, response)
        return
      end

      # Add CORS headers to all responses
      add_cors_headers(request, response)

      # Continue to next handler
      call_next(context)
    end

    private def handle_preflight(request : HTTP::Request, response : HTTP::Server::Response)
      add_cors_headers(request, response)

      # Add preflight-specific headers
      if requested_method = request.headers["Access-Control-Request-Method"]?
        if @config.allowed_methods.includes?(requested_method) || @config.allowed_methods.includes?("*")
          response.headers["Access-Control-Allow-Methods"] = @config.allowed_methods.join(", ")
        end
      end

      if requested_headers = request.headers["Access-Control-Request-Headers"]?
        if @config.allowed_headers.includes?("*")
          response.headers["Access-Control-Allow-Headers"] = requested_headers
        else
          allowed = requested_headers.split(",").map(&.strip).select do |header|
            @config.allowed_headers.includes?(header)
          end
          response.headers["Access-Control-Allow-Headers"] = allowed.join(", ") unless allowed.empty?
        end
      end

      response.headers["Access-Control-Max-Age"] = @config.max_age.to_s

      response.status_code = 204
      response.close
    end

    private def add_cors_headers(request : HTTP::Request, response : HTTP::Server::Response)
      origin = request.headers["Origin"]?

      if origin && origin_allowed?(origin)
        response.headers["Access-Control-Allow-Origin"] = origin
        response.headers["Vary"] = "Origin"

        if @config.allow_credentials?
          response.headers["Access-Control-Allow-Credentials"] = "true"
        end

        unless @config.exposed_headers.empty?
          response.headers["Access-Control-Expose-Headers"] = @config.exposed_headers.join(", ")
        end
      elsif @config.allowed_origins.includes?("*")
        response.headers["Access-Control-Allow-Origin"] = "*"
      end
    end

    private def origin_allowed?(origin : String) : Bool
      @config.allowed_origins.any? do |allowed|
        case allowed
        when "*"
          true
        when /^\*\./
          # Wildcard subdomain matching
          domain = allowed[2..]
          origin.ends_with?(domain)
        else
          origin == allowed
        end
      end
    end
  end
end
