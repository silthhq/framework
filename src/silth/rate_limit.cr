module Silth
  # Rate limiting on top of the cache (fixed window, atomic increments).
  #
  # ```
  # # In routes: middleware: [:throttle] or a custom limiter
  # scope "/api", middleware: [Silth::RateLimit::Middleware.new("api", 60, 1.minute)] do … end
  #
  # # Anywhere:
  # result = Silth::RateLimit.hit("login:#{ip}", limit: 5, period: 1.minute)
  # raise Silth::TooManyRequests.new(result.retry_after) unless result.allowed?
  # ```
  module RateLimit
    record Result, allowed : Bool, limit : Int32, remaining : Int32, reset_in : Int32 do
      def allowed? : Bool
        allowed
      end

      def retry_after : Int32
        reset_in
      end
    end

    def self.hit(key : String, limit : Int32, period : Time::Span, cost : Int32 = 1, store : CacheStore = Silth.cache) : Result
      seconds = period.total_seconds.to_i64
      window = Time.utc.to_unix // seconds
      bucket = "rl:#{key}:#{window}"
      count = store.increment(bucket, cost.to_i64, period)
      reset_in = (seconds - (Time.utc.to_unix % seconds)).to_i32
      Result.new(count <= limit, limit, {limit - count.to_i32, 0}.max, reset_in)
    end

    def self.attempts(key : String, period : Time::Span, store : CacheStore = Silth.cache) : Int64
      seconds = period.total_seconds.to_i64
      store.get("rl:#{key}:#{Time.utc.to_unix // seconds}").try(&.to_i64?) || 0_i64
    end

    def self.clear(key : String, period : Time::Span, store : CacheStore = Silth.cache) : Nil
      seconds = period.total_seconds.to_i64
      store.delete("rl:#{key}:#{Time.utc.to_unix // seconds}")
    end

    # Limits requests per client (user id when authenticated, IP otherwise).
    # Sends IETF `RateLimit-*` headers and `429` with `Retry-After`.
    class Middleware < Silth::Middleware
      def initialize(@name : String, @limit : Int32, @period : Time::Span, &@key : Context -> String)
      end

      def initialize(@name : String, @limit : Int32, @period : Time::Span)
        @key = ->(ctx : Context) { ctx.auth_user.try { |u| "user:#{u.auth_id}" } || "ip:#{ctx.remote_ip}" }
      end

      def call(ctx : Context, chain : Chain) : Nil
        result = RateLimit.hit("#{@name}:#{@key.call(ctx)}", @limit, @period)
        h = ctx.response.headers
        h["RateLimit-Limit"] = result.limit.to_s
        h["RateLimit-Remaining"] = result.remaining.to_s
        h["RateLimit-Reset"] = result.reset_in.to_s
        raise TooManyRequests.new(result.retry_after) unless result.allowed?
        chain.next(ctx)
      end
    end
  end

  # Signed, optionally expiring URLs (email verification, unsubscribe links, downloads…).
  #
  # ```
  # url = Silth::SignedURL.sign("/invoices/42/download", expires_in: 1.hour)
  # # route with middleware: [:signed] rejects tampered or expired links
  # ```
  module SignedURL
    def self.sign(path : String, expires_in : Time::Span? = nil, base : String? = nil) : String
      uri = URI.parse(path)
      params = uri.query_params
      params["expires"] = (Time.utc + expires_in).to_unix.to_s if expires_in
      params.delete("signature")
      uri.query = params.to_s.presence
      unsigned = uri.to_s
      signature = Crypto.hmac_hex(Silth.app_key, unsigned)
      separator = unsigned.includes?('?') ? '&' : '?'
      "#{base}#{unsigned}#{separator}signature=#{signature}"
    end

    def self.valid?(path_with_query : String) : Bool
      uri = URI.parse(path_with_query)
      params = uri.query_params
      signature = params["signature"]? || return false
      params.delete("signature")
      uri.query = params.to_s.presence
      expected = Crypto.hmac_hex(Silth.app_key, uri.to_s)
      return false unless Crypto.secure_compare(expected, signature)
      if exp = params["expires"]?.try(&.to_i64?)
        return false if Time.utc.to_unix > exp
      end
      true
    end

    class Middleware < Silth::Middleware
      def call(ctx : Context, chain : Chain) : Nil
        raise Forbidden.new("Invalid or expired signature") unless SignedURL.valid?(ctx.request.resource)
        chain.next(ctx)
      end
    end
  end
end
