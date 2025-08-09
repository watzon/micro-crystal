# Rate limiting middleware for API Gateway
require "http/server"

module Micro::Gateway
  # HTTP Handler for rate limiting
  class RateLimitHandler
    include HTTP::Handler

    Log = ::Log.for(self)

    getter config : RateLimitConfig
    getter limiters : Hash(String, RateLimiter)

    def initialize(@config : RateLimitConfig)
      @limiters = {} of String => RateLimiter
      @mutex = Mutex.new
    end

    def call(context : HTTP::Server::Context)
      # Get rate limit key
      key = get_rate_limit_key(context.request)

      # Get or create limiter for this key
      limiter = get_limiter(key)

      # Check rate limit
      if limiter.allow_request?
        # Add rate limit headers
        add_rate_limit_headers(context.response, limiter)
        call_next(context)
      else
        # Rate limit exceeded
        rate_limit_exceeded(context.response, limiter)
      end
    end

    private def get_rate_limit_key(request : HTTP::Request) : String
      case @config.by
      when .ip_address?
        # Get client IP
        if forwarded = request.headers["X-Forwarded-For"]?
          forwarded.split(",").first.strip
        elsif real_ip = request.headers["X-Real-IP"]?
          real_ip
        else
          request.remote_address.try(&.to_s) || "unknown"
        end
      when .user_id?
        # Get user ID from auth headers
        request.headers["X-User-ID"]? || "anonymous"
      when .api_key?
        # Get API key
        request.headers["X-API-Key"]? || "no-key"
      when .path?
        # Rate limit by path
        request.path
      else
        "global"
      end
    end

    private def get_limiter(key : String) : RateLimiter
      @mutex.synchronize do
        @limiters[key] ||= RateLimiter.new(
          @config.requests_per_minute,
          @config.burst
        )
      end
    end

    private def add_rate_limit_headers(response : HTTP::Server::Response, limiter : RateLimiter)
      response.headers["X-RateLimit-Limit"] = @config.requests_per_minute.to_s
      response.headers["X-RateLimit-Remaining"] = limiter.remaining.to_s
      response.headers["X-RateLimit-Reset"] = limiter.reset_time.to_unix.to_s
    end

    private def rate_limit_exceeded(response : HTTP::Server::Response, limiter : RateLimiter)
      response.status_code = 429
      response.content_type = "application/json"
      response.headers["Retry-After"] = (limiter.reset_time - Time.utc).total_seconds.to_i.to_s

      add_rate_limit_headers(response, limiter)

      response.print({
        "error"   => "Too Many Requests",
        "message" => "Rate limit exceeded. Please retry after #{response.headers["Retry-After"]} seconds",
      }.to_json)
      response.close
    end
  end

  # Rate limit configuration
  class RateLimitConfig
    property requests_per_minute : Int32
    property burst : Int32
    property by : RateLimitBy

    enum RateLimitBy
      IpAddress
      UserId
      ApiKey
      Path
    end

    def initialize(
      @requests_per_minute : Int32 = 60,
      @burst : Int32 = 10,
      @by : RateLimitBy = RateLimitBy::IpAddress,
    )
    end
  end

  # Token bucket rate limiter
  class RateLimiter
    getter tokens : Float64
    getter last_refill : Time
    getter reset_time : Time

    def initialize(@max_tokens : Int32, @burst : Int32)
      @tokens = @burst.to_f
      @last_refill = Time.utc
      @reset_time = Time.utc + 1.minute
      @mutex = Mutex.new
    end

    def allow_request? : Bool
      @mutex.synchronize do
        refill_tokens

        if @tokens >= 1.0
          @tokens -= 1.0
          true
        else
          false
        end
      end
    end

    def remaining : Int32
      @mutex.synchronize do
        refill_tokens
        @tokens.to_i
      end
    end

    private def refill_tokens
      now = Time.utc
      elapsed = now - @last_refill

      # Refill tokens based on time elapsed
      tokens_to_add = elapsed.total_seconds * (@max_tokens / 60.0)
      @tokens = [@tokens + tokens_to_add, @burst.to_f].min

      @last_refill = now

      # Reset time when minute boundary is crossed
      if now >= @reset_time
        @reset_time = now + 1.minute
        @tokens = @burst.to_f
      end
    end
  end
end
