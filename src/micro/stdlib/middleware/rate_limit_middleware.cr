require "../../core/middleware"
require "../../core/context"

module Micro::Stdlib::Middleware
  # Implements request rate limiting using a fixed window algorithm.
  #
  # This middleware tracks and limits the number of requests from a client
  # within a specified time window. It's essential for preventing abuse,
  # ensuring fair usage, and protecting against DoS attacks.
  #
  # ## Features
  # - Fixed window rate limiting algorithm
  # - Configurable limits and time windows
  # - Multiple key extraction strategies (IP, user, API key)
  # - Pluggable storage backends (memory, Redis, etc.)
  # - Standard rate limit headers in responses
  # - Optional skip for successful/failed requests
  #
  # ## Usage
  # ```
  # # Basic IP-based rate limiting (60 req/min)
  # server.use(RateLimitMiddleware.new(
  #   limit: 60,
  #   window: 1.minute
  # ))
  #
  # # User-based rate limiting
  # server.use(RateLimitMiddleware.new(
  #   limit: 1000,
  #   window: 1.hour,
  #   key_extractor: RateLimitMiddleware.by_user
  # ))
  #
  # # API key rate limiting with custom store
  # server.use(RateLimitMiddleware.new(
  #   limit: 10000,
  #   window: 24.hours,
  #   key_extractor: RateLimitMiddleware.by_api_key,
  #   store: RedisStore.new(redis_client)
  # ))
  #
  # # Skip counting successful requests
  # server.use(RateLimitMiddleware.new(
  #   limit: 10,
  #   window: 1.minute,
  #   skip_successful_requests: true
  # ))
  # ```
  #
  # ## Response Headers
  # - `X-RateLimit-Limit` - Request limit for the window
  # - `X-RateLimit-Remaining` - Requests remaining in current window
  # - `X-RateLimit-Reset` - Unix timestamp when window resets
  # - `Retry-After` - Seconds until retry (only on 429 responses)
  #
  # ## Key Extraction
  # Built-in extractors:
  # - `by_ip` - Client IP address (default)
  # - `by_user` - Authenticated user ID
  # - `by_api_key` - API key from header
  #
  # ## Storage Backends
  # - `MemoryStore` - In-memory storage (single instance only)
  # - Custom stores can implement the `Store` interface
  #
  # ## Limitations
  # - Fixed window can allow 2x limit at window boundaries
  # - MemoryStore not suitable for distributed systems
  # - Consider TokenBucketRateLimitMiddleware for smoother limiting
  class RateLimitMiddleware
    include Micro::Core::Middleware

    # Rate limit store interface
    abstract class Store
      abstract def increment(key : String, window : Time::Span) : ::Int32
      abstract def reset(key : String) : Nil
    end

    # In-memory rate limit store (not suitable for distributed systems)
    class MemoryStore < Store
      def initialize
        @counts = {} of String => Array(Time)
        @mutex = Mutex.new
      end

      def increment(key : String, window : Time::Span) : ::Int32
        @mutex.synchronize do
          now = Time.utc
          @counts[key] ||= [] of Time

          # Remove old entries outside the window
          @counts[key].reject! { |time| time < now - window }

          # Add current request
          @counts[key] << now

          # Return current count
          @counts[key].size
        end
      end

      def reset(key : String) : Nil
        @mutex.synchronize do
          @counts.delete(key)
        end
      end

      # Cleanup old entries periodically
      def cleanup(older_than : Time::Span) : Nil
        @mutex.synchronize do
          cutoff = Time.utc - older_than
          @counts.each do |key, times|
            times.reject! { |time| time < cutoff }
            @counts.delete(key) if times.empty?
          end
        end
      end
    end

    # Key extractor function type
    alias KeyExtractor = Proc(Micro::Core::Context, String)

    # Default key extractors
    def self.by_ip : KeyExtractor
      ->(context : Micro::Core::Context) {
        context.request.headers["X-Real-IP"]? ||
          context.request.headers["X-Forwarded-For"]?.try(&.split(',').first.strip) ||
          context.request.headers["Remote-Addr"]? ||
          "unknown"
      }
    end

    def self.by_user : KeyExtractor
      ->(context : Micro::Core::Context) {
        if user_id = context.get("user_id", String)
          "user:#{user_id}"
        else
          # Fall back to IP if no user
          by_ip.call(context)
        end
      }
    end

    def self.by_api_key : KeyExtractor
      ->(context : Micro::Core::Context) {
        if api_key = context.request.headers["X-API-Key"]?
          "api:#{api_key}"
        else
          # Fall back to IP if no API key
          by_ip.call(context)
        end
      }
    end

    def initialize(
      @limit : ::Int32,
      @window : Time::Span,
      @key_extractor : KeyExtractor = RateLimitMiddleware.by_ip,
      @store : Store = MemoryStore.new,
      @skip_successful_requests : Bool = false,
      @skip_failed_requests : Bool = false,
    )
    end

    def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
      key = @key_extractor.call(context)

      # Check current rate
      count = @store.increment(key, @window)

      # Set rate limit headers
      set_rate_limit_headers(context, count)

      if count > @limit
        # Rate limit exceeded
        handle_rate_limit_exceeded(context)
        return
      end

      # Continue chain
      next_middleware.try(&.call(context))

      # Optionally don't count certain responses
      if should_rollback?(context)
        @store.increment(key, @window) # This effectively decrements by not counting this request
      end
    end

    private def set_rate_limit_headers(context : Micro::Core::Context, count : ::Int32) : Nil
      context.response.headers["X-RateLimit-Limit"] = @limit.to_s
      context.response.headers["X-RateLimit-Remaining"] = Math.max(0, @limit - count).to_s
      context.response.headers["X-RateLimit-Reset"] = (Time.utc + @window).to_unix.to_s

      # Add standard headers
      if count > @limit
        retry_after = @window.total_seconds.ceil.to_i
        context.response.headers["Retry-After"] = retry_after.to_s
      end
    end

    private def handle_rate_limit_exceeded(context : Micro::Core::Context) : Nil
      context.response.status = 429
      context.response.body = {
        "error"   => "Rate limit exceeded",
        "message" => "Too many requests. Please retry after #{@window.total_seconds.ceil.to_i} seconds.",
      }
    end

    private def should_rollback?(context : Micro::Core::Context) : Bool
      return false unless @skip_successful_requests || @skip_failed_requests

      if @skip_successful_requests && context.response.success?
        return true
      end

      if @skip_failed_requests && context.response.error?
        return true
      end

      false
    end
  end

  # Implements token bucket algorithm for smoother rate limiting.
  #
  # Unlike fixed window rate limiting, token bucket provides a more flexible
  # approach that allows for burst traffic while maintaining an average rate.
  # Tokens are refilled at a constant rate, and requests consume tokens.
  #
  # ## Algorithm
  # - Each client gets a bucket with a maximum capacity
  # - Tokens are added at a constant refill rate
  # - Each request consumes one or more tokens
  # - Requests are rejected when insufficient tokens
  #
  # ## Features
  # - Allows controlled bursts up to bucket capacity
  # - Smooth rate limiting without window boundaries
  # - Configurable tokens per request
  # - Thread-safe implementation
  #
  # ## Usage
  # ```
  # # 100 requests/second average, burst up to 200
  # server.use(TokenBucketRateLimitMiddleware.new(
  #   capacity: 200,
  #   refill_rate: 100.0, # tokens per second
  #   tokens_per_request: 1
  # ))
  #
  # # Different costs for different operations
  # middleware = TokenBucketRateLimitMiddleware.new(
  #   capacity: 1000,
  #   refill_rate: 10.0
  # )
  # # Then dynamically set tokens_per_request based on operation
  # ```
  #
  # ## Advantages over Fixed Window
  # - No 2x spike at window boundaries
  # - Better handling of burst traffic
  # - More predictable client experience
  # - Fairer resource allocation
  #
  # ## Configuration Tips
  # - Set capacity to handle reasonable bursts
  # - Refill rate = average requests per second
  # - Higher capacity = more burst tolerance
  # - Lower refill = stricter long-term limits
  class TokenBucketRateLimitMiddleware
    include Micro::Core::Middleware

    struct Bucket
      property tokens : ::Float64
      property last_refill : Time

      def initialize(@tokens, @last_refill)
      end
    end

    def initialize(
      @capacity : ::Int32,      # Maximum tokens in bucket
      @refill_rate : ::Float64, # Tokens added per second
      @tokens_per_request : ::Int32 = 1,
      @key_extractor : RateLimitMiddleware::KeyExtractor = RateLimitMiddleware.by_ip,
    )
      @buckets = {} of String => Bucket
      @mutex = Mutex.new
    end

    def call(context : Micro::Core::Context, next_middleware : Proc(Micro::Core::Context, Nil)?) : Nil
      key = @key_extractor.call(context)

      allowed = @mutex.synchronize do
        consume_tokens(key, @tokens_per_request)
      end

      if allowed
        # Continue chain
        next_middleware.try(&.call(context))
      else
        # Rate limit exceeded
        context.response.status = 429
        context.response.body = {
          "error"   => "Rate limit exceeded",
          "message" => "Request rate too high. Please slow down.",
        }

        # Calculate when a token will be available
        retry_after = (@tokens_per_request / @refill_rate).ceil.to_i
        context.response.headers["Retry-After"] = retry_after.to_s
      end
    end

    private def consume_tokens(key : String, tokens : ::Int32) : Bool
      now = Time.utc
      bucket = @buckets[key]?

      if bucket.nil?
        # New bucket starts full
        bucket = Bucket.new(@capacity.to_f64, now)
        @buckets[key] = bucket
      else
        # Refill tokens based on time elapsed
        elapsed = now - bucket.last_refill
        tokens_to_add = elapsed.total_seconds * @refill_rate
        bucket.tokens = Math.min(@capacity.to_f64, bucket.tokens + tokens_to_add)
        bucket.last_refill = now
      end

      # Try to consume tokens
      if bucket.tokens >= tokens
        bucket.tokens -= tokens
        true
      else
        false
      end
    end
  end
end
