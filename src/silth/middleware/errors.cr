module Silth
  module Brand
    INTERNAL_CSS = {{ read_file(__DIR__ + "/../assets/internal.css") }}

    # The Silth mark: a pale mask with two hollow eyes. Uses currentColor, size it with CSS.
    LOGO_SVG = %(<svg class="s-mark" viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><path fill="currentColor" fill-rule="evenodd" d="M16 2C22.3 2 26 7 26 13.6C26 21 21.6 27.4 16 30C10.4 27.4 6 21 6 13.6C6 7 9.7 2 16 2ZM9.6 15.4a2.6 4.9 0 1 0 5.2 0a2.6 4.9 0 1 0 -5.2 0ZM17.2 15.4a2.6 4.9 0 1 0 5.2 0a2.6 4.9 0 1 0 -5.2 0Z"/></svg>)

    # Standalone icon (dark square, pale mask): served at `/_silth/logo.svg` and used as favicon.
    ICON_SVG = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="7" fill="#07080c"/><path fill="#ecebf5" fill-rule="evenodd" transform="translate(3.2 3.2) scale(.8)" d="M16 2C22.3 2 26 7 26 13.6C26 21 21.6 27.4 16 30C10.4 27.4 6 21 6 13.6C6 7 9.7 2 16 2ZM9.6 15.4a2.6 4.9 0 1 0 5.2 0a2.6 4.9 0 1 0 -5.2 0ZM17.2 15.4a2.6 4.9 0 1 0 5.2 0a2.6 4.9 0 1 0 -5.2 0Z"/></svg>)
    FAVICON  = "data:image/svg+xml," + URI.encode_path(ICON_SVG)

    def self.page(title : String, body : String, nonce : String? = nil) : String
      <<-HTML
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>#{HTML.escape(title)}</title><link rel="icon" href="#{FAVICON}"><style#{nonce ? %( nonce="#{nonce}") : ""}>#{INTERNAL_CSS}</style></head><body>#{body}</body></html>
        HTML
    end
  end

  # Hooks called for every unhandled exception (log, profiler, telemetry, error trackers…).
  module ErrorReporter
    class_getter reporters = [] of Proc(Exception, Context?, Nil)

    def self.on_report(&block : Exception, Context? -> Nil) : Nil
      @@reporters << block
    end

    def self.report(ex : Exception, ctx : Context? = nil) : Nil
      @@reporters.each do |r|
        r.call(ex, ctx)
      rescue err
        ::Log.for("silth.errors").error(exception: err) { "Error reporter failed" }
      end
    end
  end

  # Converts exceptions to responses: rich debug page in development,
  # polished pages in production, RFC 9457 JSON for API clients.
  class ErrorHandlerMiddleware < Middleware
    Log = ::Log.for("silth.errors")

    def initialize(@debug : Bool = false)
    end

    def call(ctx : Context, chain : Chain) : Nil
      chain.next(ctx)
    rescue ex : Exception
      handle(ctx, ex)
    end

    def handle(ctx : Context, ex : Exception) : Nil
      status = case ex
               when HTTPError                then ex.status.code
               when Silth::ORM::RecordNotFound then 404
               when Silth::ORM::RecordInvalid  then 422
               else                               500
               end
      if status >= 500
        Log.error(exception: ex) { "#{ex.class.name}: #{ex.message}" }
        ErrorReporter.report(ex, ctx)
      else
        Log.debug { "#{status} #{ex.class.name}: #{ex.message}" }
      end
      if ctx.responded?
        return
      end
      if ex.is_a?(HTTPError)
        ex.headers.each { |k, v| ctx.response.headers[k] = v }
      end
      if custom = Silth.app.error_renderer
        return if custom.call(ctx, ex, status)
      end
      message = status >= 500 && !@debug ? "Something went wrong on our side." : (ex.message || "Error")
      if ctx.wants_json?
        details = ex.is_a?(HTTPError) ? ex.details : (ex.is_a?(Silth::ORM::RecordInvalid) ? ex.errors.to_h : nil)
        ctx.problem(status, HTTP::Status.new(status).description || "Error", message, details)
      elsif @debug && status >= 500
        ctx.html(DebugPage.render(ctx, ex), status)
      else
        ctx.html(ErrorPage.render(status, message, ctx.csp_nonce), status)
      end
    end
  end

  module ErrorPage
    def self.render(status : Int32, message : String, nonce : String? = nil) : String
      title = HTTP::Status.new(status).description || "Error"
      Brand.page("#{status} · #{title}", <<-HTML, nonce)
        <main class="s-center"><div>
          <div class="s-glyph" style="width:40px;height:40px;margin:0 auto">#{Brand::LOGO_SVG.sub(%(class="s-mark"), %(width="40" height="40"))}</div>
          <p class="s-big">#{status}</p>
          <h1 class="s-title">#{HTML.escape(title)}</h1>
          <p class="s-sub" style="max-width:460px;margin:8px auto 22px">#{HTML.escape(message)}</p>
          <a class="s-btn" href="/">Back to home</a>
        </div></main>
        HTML
    end
  end

  # Development exception page: source excerpts, backtrace, request and session data.
  module DebugPage
    FRAME = /^(?<file>.+?):(?<line>\d+):(?<col>\d+) in '(?<fn>.*)'$/

    def self.render(ctx : Context, ex : Exception) : String
      frames = (ex.backtrace? || [] of String).first(60)
      app_root = Dir.current
      first_app = frames.index { |f| app_frame?(f, app_root) } || 0
      excerpt = frames[first_app]?.try { |f| source_excerpt(f) } || ""
      trace = String.build do |io|
        frames.each_with_index do |frame, i|
          is_app = app_frame?(frame, app_root)
          if m = FRAME.match(frame)
            io << %(<div class="s-frame#{is_app ? " app" : ""}"><div class="loc">) << HTML.escape(relative(m["file"], app_root)) << ':' << m["line"] << %(</div><div class="fn">) << HTML.escape(m["fn"]) << "</div>"
            io << source_excerpt(frame) if is_app && i != first_app && i < 12
            io << "</div>"
          else
            io << %(<div class="s-frame"><div class="fn">) << HTML.escape(frame) << "</div></div>"
          end
        end
      end
      cause = ex.cause.try { |c| %(<p class="s-sub">Caused by <span class="s-error-class">#{HTML.escape(c.class.name)}</span>: #{HTML.escape(c.message || "")}</p>) } || ""
      body = <<-HTML
        <div class="s-wrap">
          <div class="s-brand" style="margin-bottom:16px">#{Brand::LOGO_SVG} silth <small>debug</small></div>
          <div class="s-card">
            <div class="s-error-class">#{HTML.escape(ex.class.name)}</div>
            <h1 class="s-title">#{HTML.escape(ex.message || "(no message)")}</h1>
            <p class="s-sub">#{HTML.escape(ctx.method)} #{HTML.escape(ctx.request.resource)} · #{HTML.escape(ctx.route.try(&.handler_name) || "no route")} · request #{ctx.id}</p>
            #{cause}
            #{excerpt}
          </div>
          <div class="s-card"><h3 style="margin-top:0">Backtrace</h3>#{trace.empty? ? %(<p class="s-muted">No backtrace available: build with debug info.</p>) : trace}</div>
          <div class="s-card"><h3 style="margin-top:0">Request</h3>#{kv(request_info(ctx))}</div>
          <div class="s-card"><h3 style="margin-top:0">Params</h3>#{kv(ctx.params?.try(&.to_h) || {} of String => String)}</div>
          <div class="s-card"><h3 style="margin-top:0">Headers</h3>#{kv(ctx.request.headers.to_h.transform_values(&.join(", ")))}</div>
          <div class="s-card"><h3 style="margin-top:0">Session</h3>#{kv(ctx.session?.try(&.data) || {} of String => String)}</div>
          <p class="s-muted">This page is only shown when <code>app.debug</code> is enabled. Never enable it in production.</p>
        </div>
        HTML
      Brand.page("#{ex.class.name} · Silth", body, ctx.csp_nonce)
    end

    def self.app_frame?(frame : String, root : String) : Bool
      m = FRAME.match(frame) || return false
      file = m["file"]
      !file.includes?("/lib/") && !file.includes?("/share/crystal/") && !file.includes?("crystal/src/") &&
        (file.starts_with?("src/") || file.starts_with?("spec/") || file.starts_with?(root) || file.starts_with?("config/"))
    end

    def self.relative(file : String, root : String) : String
      file.starts_with?(root) ? file[(root.size + 1)..] : file
    end

    def self.source_excerpt(frame : String, radius : Int32 = 6) : String
      m = FRAME.match(frame) || return ""
      file = m["file"]
      line = m["line"].to_i
      return "" unless File.file?(file)
      lines = File.read_lines(file)
      from = {line - radius, 1}.max
      to = {line + radius, lines.size}.min
      String.build do |io|
        io << %(<div class="s-code"><pre>)
        (from..to).each do |n|
          io << %(<div class="ln) << (n == line ? " hl" : "") << %("><span>) << n << "</span><span>" << HTML.escape(lines[n - 1]) << "</span></div>"
        end
        io << "</pre></div>"
      end
    rescue
      ""
    end

    private def self.request_info(ctx : Context) : Hash(String, String)
      {
        "Method"     => ctx.method,
        "URL"        => ctx.url,
        "Route"      => ctx.route.try(&.path) || "-",
        "Handler"    => ctx.route.try(&.handler_name) || "-",
        "Remote IP"  => ctx.remote_ip,
        "Locale"     => ctx.locale,
        "User"       => ctx.auth_user.try(&.auth_id.to_s) || "guest",
        "Crystal"    => Crystal::VERSION,
        "Silth"      => Silth::VERSION,
        "Environment" => Silth.env,
      }
    end

    private def self.kv(hash : Hash(String, String)) : String
      return %(<p class="s-muted">Empty</p>) if hash.empty?
      String.build do |io|
        io << %(<table class="s-table s-kv">)
        hash.each do |k, v|
          shown = k.downcase.matches?(/password|secret|token|cookie|authorization/) ? "••••••" : v
          io << "<tr><td>" << HTML.escape(k) << "</td><td><code>" << HTML.escape(shown) << "</code></td></tr>"
        end
        io << "</table>"
      end
    end
  end
end
