module Silth
  # Adds `X-Request-Id` and binds it to the log context.
  class RequestIdMiddleware < Middleware
    def call(ctx : Context, chain : Chain) : Nil
      ctx.response.headers["X-Request-Id"] = ctx.id
      ::Log.with_context(request_id: ctx.id) do
        chain.next(ctx)
      end
    end
  end

  # Logs one line per request: `GET /posts 200 3.2ms`.
  class RequestLoggerMiddleware < Middleware
    Log = ::Log.for("silth.http")

    def initialize(@skip_paths : Array(String) = ["/up", "/_silth/livereload"])
    end

    def call(ctx : Context, chain : Chain) : Nil
      chain.next(ctx)
    ensure
      unless @skip_paths.any? { |p| ctx.path.starts_with?(p) } || ctx.path.starts_with?("/_silth/profiler")
        status = ctx.status
        Log.info &.emit("#{ctx.method} #{ctx.request.resource} #{status} #{ctx.duration_ms.round(2)}ms",
          route: ctx.route.try(&.handler_name) || "-", ip: ctx.remote_ip)
      end
    end
  end

  # Allows HTML forms to use PUT/PATCH/DELETE through a `_method` field.
  class MethodOverrideMiddleware < Middleware
    ALLOWED = %w(PUT PATCH DELETE)

    def call(ctx : Context, chain : Chain) : Nil
      if ctx.request.method == "POST"
        override = ctx.request.headers["X-HTTP-Method-Override"]?
        if override.nil? && (ctx.request.headers["Content-Type"]? || "").matches?(/form/)
          override = ctx.params["_method"]?
        end
        if override && ALLOWED.includes?(override.upcase)
          ctx.request.method = override.upcase
        end
      end
      chain.next(ctx)
    end
  end

  # Returns 503 while `tmp/maintenance` exists (`silth down` / `silth up`).
  class MaintenanceMiddleware < Middleware
    FILE = "tmp/maintenance"

    def call(ctx : Context, chain : Chain) : Nil
      if File.exists?(FILE)
        secret = File.read(FILE).strip
        bypass = !secret.empty? && (ctx.request.query_params["secret"]? == secret || ctx.cookies["silth_bypass"]?.try(&.value) == secret)
        unless bypass
          ctx.response.headers["Retry-After"] = "60"
          raise ServiceUnavailable.new("Be right back — we are performing maintenance.")
        end
        ctx.set_cookie("silth_bypass", secret, max_age: 12.hours) if ctx.request.query_params["secret"]?
      end
      chain.next(ctx)
    end
  end

  # Security headers with a per-request CSP nonce (`csp_nonce` helper).
  # *extra* (`security.headers` in `config/security.yml`) adds headers or
  # replaces the defaults (`X-Frame-Options: DENY`); an empty value removes one.
  class SecureHeadersMiddleware < Middleware
    def initialize(@csp : String? = nil, @hsts : Bool = false, @extra : Hash(String, String) = {} of String => String)
    end

    def call(ctx : Context, chain : Chain) : Nil
      nonce = Crypto.token(16)
      ctx.csp_nonce = nonce
      headers = ctx.response.headers
      headers["X-Content-Type-Options"] = "nosniff"
      headers["X-Frame-Options"] = "SAMEORIGIN"
      headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
      headers["Cross-Origin-Opener-Policy"] = "same-origin"
      headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=(), interest-cohort=()"
      headers["Strict-Transport-Security"] = "max-age=63072000; includeSubDomains" if @hsts
      if csp = @csp
        headers["Content-Security-Policy"] = csp.gsub("{nonce}", nonce)
      end
      @extra.each { |name, value| value.empty? ? headers.delete(name) : (headers[name] = value) }
      chain.next(ctx)
    end
  end

  # CORS for APIs. Configure in `config/cors.yml`.
  class CORSMiddleware < Middleware
    def initialize(@origins : Array(String), @methods : Array(String) = %w(GET POST PUT PATCH DELETE OPTIONS),
                   @headers : Array(String) = %w(Content-Type Authorization X-Requested-With X-CSRF-Token),
                   @credentials : Bool = false, @max_age : Int32 = 7200, @paths : Array(String) = ["/api"])
    end

    def call(ctx : Context, chain : Chain) : Nil
      origin = ctx.header("Origin")
      if origin && @paths.any? { |p| ctx.path.starts_with?(p) } && allowed?(origin)
        h = ctx.response.headers
        h["Access-Control-Allow-Origin"] = @origins.includes?("*") && !@credentials ? "*" : origin
        h["Vary"] = "Origin"
        h["Access-Control-Allow-Credentials"] = "true" if @credentials
        if ctx.request.method == "OPTIONS"
          h["Access-Control-Allow-Methods"] = @methods.join(", ")
          h["Access-Control-Allow-Headers"] = @headers.join(", ")
          h["Access-Control-Max-Age"] = @max_age.to_s
          ctx.head(204)
          return
        end
      end
      chain.next(ctx)
    end

    private def allowed?(origin : String) : Bool
      @origins.any? do |o|
        o == "*" || o == origin || (o.includes?('*') && Regex.new("\\A" + Regex.escape(o).gsub("\\*", "[^.]+") + "\\z").matches?(origin))
      end
    end
  end

  # Loads and persists the session (cookie or cache store) and the flash.
  class SessionMiddleware < Middleware
    def call(ctx : Context, chain : Chain) : Nil
      store = Silth.session_store
      session = store.load(ctx) || Session.new
      ctx.session = session
      ctx.before_send do
        ctx.flash?.try &.persist(session)
        store.save(ctx, session) if session.changed? || session.regenerated? || ctx.flash?
      end
      chain.next(ctx)
    end
  end

  # Health check endpoint (`GET /up`) for load balancers.
  class HealthMiddleware < Middleware
    def initialize(@path : String = "/up")
    end

    def call(ctx : Context, chain : Chain) : Nil
      if ctx.path == @path && ctx.get?
        checks = Silth.health_checks.map { |name, check| {name, (check.call rescue false)} }.to_h
        ok = checks.values.all?
        ctx.json({status: ok ? "ok" : "degraded", checks: checks}, ok ? 200 : 503)
      else
        chain.next(ctx)
      end
    end
  end
end
