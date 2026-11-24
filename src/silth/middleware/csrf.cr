module Silth
  # Cross-Site Request Forgery protection.
  #
  # Two layers, both enabled by default in the `web` middleware group:
  # 1. Fetch metadata / Origin check: cross-site unsafe requests are rejected outright.
  # 2. Synchronizer token: forms must send `_csrf` (or the `X-CSRF-Token` header).
  #    Tokens are masked per render (BREACH mitigation), so every form gets a different value.
  module CSRF
    FIELD       = "_csrf"
    HEADER      = "X-CSRF-Token"
    SESSION_KEY = "_csrf_token"
    SAFE        = %w(GET HEAD OPTIONS TRACE)

    def self.raw_token(ctx : Context) : Bytes
      session = ctx.session? || return Bytes.new(32)
      if existing = session[SESSION_KEY]?
        decoded = Base64.decode(existing) rescue nil
        return decoded if decoded && decoded.size == 32
      end
      token = Random::Secure.random_bytes(32)
      session[SESSION_KEY] = Base64.strict_encode(token)
      token
    end

    def self.masked_token(ctx : Context) : String
      raw = raw_token(ctx)
      pad = Random::Secure.random_bytes(32)
      masked = Bytes.new(32) { |i| pad[i] ^ raw[i] }
      combined = Bytes.new(64)
      pad.copy_to(combined)
      masked.copy_to(combined + 32)
      Base64.urlsafe_encode(combined, padding: false)
    end

    def self.valid?(ctx : Context, provided : String?) : Bool
      return false if provided.nil? || provided.empty?
      decoded = Base64.decode(provided) rescue return false
      raw = raw_token(ctx)
      candidate = case decoded.size
                  when 64 then Bytes.new(32) { |i| decoded[i] ^ decoded[i + 32] }
                  when 32 then decoded
                  else         return false
                  end
      Crypto.secure_compare(candidate, raw)
    end

    def self.rotate(ctx : Context) : Nil
      ctx.session?.try &.delete(SESSION_KEY)
    end
  end

  class CSRFMiddleware < Middleware
    def initialize(@except : Array(String) = [] of String, @trusted_origins : Array(String) = [] of String)
    end

    def call(ctx : Context, chain : Chain) : Nil
      unless CSRF::SAFE.includes?(ctx.request.method) || skipped?(ctx)
        verify_origin!(ctx)
        provided = ctx.header(CSRF::HEADER) || ctx.params[CSRF::FIELD]?
        raise CSRFError.new("CSRF token missing or invalid. Include csrf_field in your form.") unless CSRF.valid?(ctx, provided)
      end
      chain.next(ctx)
    end

    private def skipped?(ctx : Context) : Bool
      return true if Silth.test? && !Silth.config.bool("security.csrf_in_tests", false)
      # Token authenticated API calls are not vulnerable to CSRF.
      return true if ctx.header("Authorization").try(&.starts_with?("Bearer "))
      @except.any? do |pattern|
        pattern.ends_with?('*') ? ctx.path.starts_with?(pattern.rchop('*')) : ctx.path == pattern
      end
    end

    private def verify_origin!(ctx : Context) : Nil
      if site = ctx.header("Sec-Fetch-Site")
        return if site == "same-origin" || site == "none"
      end
      origin = ctx.header("Origin")
      return if origin.nil?
      host = URI.parse(origin).host rescue nil
      return if host && host == ctx.host.split(':').first
      return if @trusted_origins.includes?(origin)
      raise CSRFError.new("Cross-origin request blocked (origin #{origin})")
    end
  end
end
