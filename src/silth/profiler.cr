class Fiber
  # :nodoc:
  property silth_profile : Silth::Profiler::Profile?
end

module Silth
  # Development profiler: a debug toolbar on every HTML page plus a dashboard at
  # `/_silth/profiler` with requests, queries, logs, events, cache, mails, jobs,
  # outgoing HTTP calls, exceptions, routes, scheduled tasks and workflows.
  #
  # ```yaml
  # # config/profiler.yml
  # enabled: true            # default: development only
  # toolbar: true
  # keep: 200                # profiles kept in memory
  # slow_query_ms: 100
  # ```
  module Profiler
    record QueryEntry, sql : String, args : Array(String), ms : Float64, connection : String, rows : Int32
    record LogEntry, level : String, source : String, message : String, at : Time
    record Entry, kind : String, label : String, detail : String, at : Time, ms : Float64? = nil

    class Profile
      getter token : String = Crypto.hex_token(6)
      getter started_at : Time = Time.utc
      property method = ""
      property path = ""
      property url = ""
      property status = 0
      property route = "-"
      property handler = "-"
      property duration_ms = 0.0
      property memory_kb = 0_i64
      property user : String? = nil
      property ip = ""
      getter queries = [] of QueryEntry
      getter logs = [] of LogEntry
      getter entries = [] of Entry
      getter exceptions = [] of {String, String, Array(String)}
      property request_headers = {} of String => String
      property response_headers = {} of String => String
      property params = {} of String => String
      property session = {} of String => String

      def query_ms : Float64
        @queries.sum(&.ms)
      end

      def count(kind : String) : Int32
        @entries.count { |e| e.kind == kind }
      end

      def duplicated_queries : Int32
        @queries.group_by(&.sql).count { |_, v| v.size > 1 }
      end
    end

    @@profiles = Deque(Profile).new
    @@background = Deque(Entry).new
    @@mutex = Mutex.new
    @@enabled : Bool? = nil

    def self.enabled? : Bool
      @@enabled = Silth.config.bool("profiler.enabled", Silth.development?) if @@enabled.nil?
      @@enabled.not_nil!
    end

    def self.enabled=(value : Bool) : Nil
      @@enabled = value
    end

    def self.profiles : Array(Profile)
      @@mutex.synchronize { @@profiles.to_a.reverse }
    end

    def self.find(token : String) : Profile?
      @@mutex.synchronize { @@profiles.find { |p| p.token == token } }
    end

    def self.background : Array(Entry)
      @@mutex.synchronize { @@background.to_a.reverse }
    end

    def self.store(profile : Profile) : Nil
      keep = Silth.config.int("profiler.keep", 200)
      @@mutex.synchronize do
        @@profiles << profile
        while @@profiles.size > keep
          @@profiles.shift
        end
      end
    end

    private def self.record_background(entry : Entry) : Nil
      @@mutex.synchronize do
        @@background << entry
        while @@background.size > 500
          @@background.shift
        end
      end
    end

    def self.clear : Nil
      @@mutex.synchronize { @@profiles.clear; @@background.clear }
    end

    def self.boot : Nil
      return unless enabled?
      Instrument.subscribe do |event|
        profile = Fiber.current.silth_profile
        entry = case event
                when Instrument::Query
                  if p = profile
                    p.queries << QueryEntry.new(event.sql, event.args, event.duration.total_milliseconds, event.connection, event.rows)
                  end
                  nil
                when Instrument::Cache        then Entry.new("cache", "#{event.operation} #{event.key}", event.hit ? "hit" : "miss", event.at)
                when Instrument::Mail         then Entry.new("mail", event.subject, "to #{event.to} (#{event.mailer})", event.at)
                when Instrument::Job          then Entry.new("job", event.name, "#{event.status} on #{event.queue}", event.at, event.duration.try(&.total_milliseconds))
                when Instrument::AppEvent     then Entry.new("event", event.name, "#{event.listeners} listener(s)", event.at)
                when Instrument::HTTPCall     then Entry.new("http", "#{event.method} #{event.url}", event.status.to_s, event.at, event.duration.total_milliseconds)
                when Instrument::Notification then Entry.new("notification", event.name, event.channels, event.at)
                when Instrument::Render       then Entry.new("view", event.template, "", event.at, event.duration.total_milliseconds)
                when Instrument::Custom       then Entry.new("custom", event.name, event.data.map { |k, v| "#{k}=#{v}" }.join(" "), event.at)
                else                               nil
                end
        if e = entry
          if p = profile
            p.entries << e
          else
            record_background(e)
          end
        end
      end
      Logging.on_entry do |log|
        next if log.source.starts_with?("silth.http")
        level = log.severity.label.downcase
        line = LogEntry.new(level, log.source, log.message, log.timestamp)
        if p = Fiber.current.silth_profile
          p.logs << line
        elsif log.severity >= ::Log::Severity::Warn
          record_background(Entry.new("log", "#{level} #{log.source}", log.message, log.timestamp))
        end
      end
      ErrorReporter.on_report do |ex, _ctx|
        trace = (ex.backtrace? || [] of String).first(25)
        if p = Fiber.current.silth_profile
          p.exceptions << {ex.class.name, ex.message || "", trace}
        else
          record_background(Entry.new("exception", ex.class.name, ex.message || "", Time.utc))
        end
      end
    end

    # Collects the profile and serves the dashboard.
    class Middleware < Silth::Middleware
      PREFIX = "/_silth/profiler"

      def call(ctx : Context, chain : Chain) : Nil
        if ctx.path.starts_with?(PREFIX)
          return Dashboard.serve(ctx)
        end
        if ctx.path.starts_with?("/_silth/") || ctx.path.starts_with?("/assets/")
          return chain.next(ctx)
        end
        profile = Profile.new
        profile.method = ctx.method
        profile.path = ctx.path
        profile.url = ctx.request.resource
        profile.ip = ctx.remote_ip
        Fiber.current.silth_profile = profile
        before_heap = GC.stats.heap_size
        ctx.response.headers["X-Silth-Profile"] = profile.token
        if Silth.config.bool("profiler.toolbar", true)
          ctx.filter_body do |body, content_type|
            finalize_profile(ctx, profile, before_heap)
            if content_type.starts_with?("text/html") && (idx = body.rindex("</body>"))
              body.insert(idx, Toolbar.render(profile, ctx.csp_nonce))
            else
              body
            end
          end
        end
        begin
          chain.next(ctx)
        ensure
          finalize_profile(ctx, profile, before_heap)
          Profiler.store(profile)
          Fiber.current.silth_profile = nil
        end
      end

      private def finalize_profile(ctx : Context, profile : Profile, before_heap) : Nil
        profile.status = ctx.status
        profile.route = ctx.route.try(&.path) || "-"
        profile.handler = ctx.route.try(&.handler_name) || "-"
        profile.duration_ms = ctx.duration_ms
        profile.memory_kb = ((GC.stats.heap_size.to_i64 - before_heap.to_i64) // 1024)
        profile.user = ctx.auth_user.try { |u| "#{u.class.name}##{u.auth_id}" }
        profile.request_headers = ctx.request.headers.to_h.transform_values(&.join(", ")).reject { |k, _| k.downcase.in?("cookie", "authorization") }
        profile.response_headers = ctx.response.headers.to_h.transform_values(&.join(", ")).reject { |k, _| k.downcase == "set-cookie" }
        profile.params = ctx.params?.try(&.to_h.reject { |k, _| k.downcase.includes?("password") || k == "_csrf" }) || {} of String => String
        profile.session = ctx.session?.try(&.data.reject { |k, _| k.starts_with?("_csrf") }) || {} of String => String
      end
    end

    module Toolbar
      def self.render(p : Profile, nonce : String?) : String
        status_class = p.status >= 500 ? "err" : p.status >= 400 ? "warn" : "ok"
        warns = p.logs.count { |l| l.level.in?("warn", "error", "fatal") }
        n = nonce ? %( nonce="#{nonce}") : ""
        <<-HTML
          <div id="silth-toolbar"><style#{n}>
          #silth-toolbar{position:fixed;left:0;right:0;bottom:0;z-index:2147483000;font:12px/1 "JetBrains Mono",ui-monospace,Menlo,monospace;color:#ecebf5}
          #silth-toolbar .bar{display:flex;align-items:center;gap:2px;background:rgba(7,8,12,.94);border-top:1px solid #262b3b;backdrop-filter:blur(8px);height:34px;overflow-x:auto}
          #silth-toolbar a{color:inherit;text-decoration:none;display:flex;align-items:center;gap:6px;height:34px;padding:0 12px;border-right:1px solid #1a1e2b;white-space:nowrap}
          #silth-toolbar a:hover{background:#131620}
          #silth-toolbar .logo svg{width:16px;height:16px}
          #silth-toolbar .ok{color:#82dcae}#silth-toolbar .warn{color:#e3bb74}#silth-toolbar .err{color:#ff6b81}#silth-toolbar .muted{color:#8a8fa6}
          #silth-toolbar .close{margin-left:auto;cursor:pointer;padding:0 12px;color:#8a8fa6;background:none;border:0;font:inherit}
          #silth-toolbar.min .bar a:not(.logo){display:none}
          </style><div class="bar">
            <a class="logo" href="#{Middleware::PREFIX}" title="Silth profiler">#{Brand::LOGO_SVG}</a>
            <a href="#{Middleware::PREFIX}/#{p.token}" class="#{status_class}">#{p.status} <span class="muted">#{HTML.escape(p.method)}</span></a>
            <a href="#{Middleware::PREFIX}/#{p.token}" title="Route">#{HTML.escape(p.handler)}</a>
            <a href="#{Middleware::PREFIX}/#{p.token}#timeline" title="Total time">⏱ #{p.duration_ms.round(1)} ms</a>
            <a href="#{Middleware::PREFIX}/#{p.token}#queries" title="Database" class="#{p.queries.size > 20 || p.duplicated_queries > 0 ? "warn" : ""}">⛁ #{p.queries.size} <span class="muted">#{p.query_ms.round(1)} ms</span></a>
            <a href="#{Middleware::PREFIX}/#{p.token}#logs" class="#{warns > 0 ? "warn" : ""}" title="Logs">≡ #{p.logs.size}#{warns > 0 ? " · #{warns}⚠" : ""}</a>
            <a href="#{Middleware::PREFIX}/#{p.token}#events" title="Events, cache, mails, jobs">◆ #{p.entries.size}</a>
            <a href="#{Middleware::PREFIX}/#{p.token}#request" title="Memory">#{p.memory_kb} KB</a>
            <a href="#{Middleware::PREFIX}/#{p.token}#request" title="User">#{HTML.escape(p.user || "guest")}</a>
            <button class="close" type="button" aria-label="Minimize toolbar">▾</button>
          </div><script#{n}>(()=>{const t=document.getElementById("silth-toolbar");if(localStorage.getItem("silth-tb")==="min")t.classList.add("min");t.querySelector(".close").onclick=()=>{t.classList.toggle("min");localStorage.setItem("silth-tb",t.classList.contains("min")?"min":"")}})()</script></div>
          HTML
      end
    end

    # The Mails tab: previews (`Silth::MailPreview`), mails captured by the memory
    # transport and `.eml` files written by the file transport.
    #
    # ```text
    # /_silth/profiler/mails                               list
    # /_silth/profiler/mails/preview/<Preview>/<method>    one preview (…/html, …/eml)
    # /_silth/profiler/mails/sent/<n>                      a captured mail (…/html, …/eml)
    # /_silth/profiler/mails/file/<name>.eml               a file written by the file transport
    # ```
    module MailViewer
      PREFIX = "#{Middleware::PREFIX}/mails"

      def self.index : String
        previews = MailPreview.all.flat_map do |(klass, methods)|
          methods.map { |m| %(<tr><td><a class="mono" href="#{PREFIX}/preview/#{klass}/#{m}">#{HTML.escape(klass)}##{HTML.escape(m)}</a></td></tr>) }
        end.join
        sent = Mailer.sent.each_with_index.to_a.reverse.first(50).map do |(m, i)|
          %(<tr><td><a href="#{PREFIX}/sent/#{i}">#{HTML.escape(m.subject_line)}</a></td><td class="s-muted">#{HTML.escape(m.recipients.join(", "))}</td><td class="s-muted">#{m.class.name}</td></tr>)
        end.join
        files = eml_files.first(50).map { |f| %(<tr><td><a class="mono" href="#{PREFIX}/file/#{File.basename(f)}">#{HTML.escape(File.basename(f))}</a></td><td class="s-muted">#{File.size(f)} bytes</td></tr>) }.join
        <<-HTML
          <h1 class="s-title">Mails</h1>
          <div class="s-card"><h3 style="margin-top:0">Previews</h3><table class="s-table"><tbody>#{previews.empty? ? %(<tr><td class="s-muted">No preview. Add a <code>Silth::MailPreview</code> subclass in src/mails/previews.</td></tr>) : previews}</tbody></table></div>
          <div class="s-card"><h3 style="margin-top:0">Captured (memory transport)</h3><table class="s-table"><tbody>#{sent.empty? ? %(<tr><td class="s-muted">None.</td></tr>) : sent}</tbody></table></div>
          <div class="s-card"><h3 style="margin-top:0">tmp/mails (file transport)</h3><table class="s-table"><tbody>#{files.empty? ? %(<tr><td class="s-muted">None.</td></tr>) : files}</tbody></table></div>
          HTML
      end

      def self.show(rest : String) : String
        mail, base = find(rest) || raise NotFound.new("No such mail")
        headers = {"Subject" => mail.subject_line, "From" => mail.from_address.to_s, "To" => mail.to_list.join(", "),
                   "Cc" => mail.cc_list.join(", "), "Reply-To" => mail.reply_to_address.to_s}.reject { |_, v| v.empty? }
        attachments = mail.attachments.map { |a| %(<span class="s-badge">#{HTML.escape(a.filename)} · #{a.content.size} bytes</span>) }.join(" ")
        html = mail.html_body ? %(<iframe sandbox src="#{base}/html" title="HTML body" style="width:100%;height:640px;border:1px solid var(--line);border-radius:8px;background:#fff"></iframe>) : %(<p class="s-muted">No HTML body.</p>)
        text = mail.text_body || mail.html_body.try { |h| Mailer.html_to_text(h) } || ""
        <<-HTML
          <p class="s-sub"><a href="#{PREFIX}">← Mails</a> · <a href="#{base}/eml">Download .eml</a></p>
          <div class="s-card"><h1 class="s-title" style="font-size:20px">#{HTML.escape(mail.subject_line)}</h1><table class="s-table s-kv">#{headers.map { |k, v| %(<tr><td>#{k}</td><td>#{HTML.escape(v)}</td></tr>) }.join}</table>#{attachments.empty? ? "" : %(<p>#{attachments}</p>)}</div>
          <div class="s-card"><h3 style="margin-top:0">HTML</h3>#{html}</div>
          <div class="s-card"><h3 style="margin-top:0">Text</h3><pre class="mono" style="white-space:pre-wrap">#{HTML.escape(text)}</pre></div>
          HTML
      end

      # `…/html`, `…/eml` and `.eml` files are served as is, outside the layout.
      def self.raw?(rest : String) : Bool
        rest.starts_with?("mails/") && (rest.ends_with?("/html") || rest.ends_with?("/eml") || rest.starts_with?("mails/file/"))
      end

      def self.serve_raw(ctx : Context, rest : String) : Nil
        if name = rest.lchop?("mails/file/")
          path = eml_files.find { |f| File.basename(f) == name } || raise NotFound.new("No such file")
          return ctx.text(File.read(path))
        end
        mail, _ = find(rest.rchop("/html").rchop("/eml")) || raise NotFound.new("No such mail")
        if rest.ends_with?("/eml")
          ctx.response.headers["Content-Disposition"] = %(attachment; filename="#{mail.class.name.underscore.gsub("::", "_")}.eml")
          return ctx.text(mail.to_mime)
        end
        # The mail's own inline styles, nothing else (the page is also sandboxed).
        ctx.response.headers["Content-Security-Policy"] = "default-src 'none'; img-src * data:; style-src 'unsafe-inline'; font-src * data:"
        ctx.html(mail.html_body || "")
      end

      # The mail designated by `mails/preview/<class>/<method>` or `mails/sent/<n>`, and its URL.
      private def self.find(rest : String) : {Mail, String}?
        parts = rest.split('/')
        mail = case parts[1]?
               when "preview" then MailPreview.render(parts[2]? || "", parts[3]? || "")
               when "sent"    then parts[2]?.try(&.to_i?).try { |i| Mailer.sent[i]? }
               end
        mail.try { |m| {m, "#{Middleware::PREFIX}/#{parts[0, parts[1]? == "preview" ? 4 : 3].join('/')}"} }
      end

      private def self.eml_files : Array(String)
        Dir.exists?("tmp/mails") ? Dir.glob("tmp/mails/*.eml").sort.reverse : [] of String
      end
    end

    # The `/_silth/profiler` web UI.
    module Dashboard
      def self.serve(ctx : Context) : Nil
        rest = ctx.path.lchop(Middleware::PREFIX).strip('/')
        if ctx.request.method == "POST" && rest == "clear"
          Profiler.clear
          return ctx.redirect(Middleware::PREFIX)
        end
        return MailViewer.serve_raw(ctx, rest) if MailViewer.raw?(rest)
        body = case rest
               when ""                      then index(ctx)
               when "activity"              then activity
               when "routes"                then routes
               when "schedule"              then schedule
               when "workflows"             then workflows
               when "mails"                 then MailViewer.index
               when .starts_with?("mails/") then MailViewer.show(rest)
               else
                 profile = Profiler.find(rest) || raise NotFound.new("Profile #{rest} expired")
                 show(profile)
               end
        ctx.html(Brand.page("Silth Profiler", layout(rest.starts_with?("mails") ? "mails" : rest, body), ctx.csp_nonce))
      end

      private def self.layout(active : String, body : String) : String
        tabs = {"" => "Requests", "activity" => "Activity", "mails" => "Mails", "routes" => "Routes", "schedule" => "Schedule", "workflows" => "Workflows"}
        nav = tabs.map { |k, v| %(<a href="#{Middleware::PREFIX}/#{k}" class="#{active == k ? "active" : ""}">#{v}</a>) }.join
        <<-HTML
          <nav class="s-nav"><span class="s-brand">#{Brand::LOGO_SVG} Silth profiler</span>#{nav}
          <form method="post" action="#{Middleware::PREFIX}/clear" style="margin-left:auto"><button class="s-badge" style="cursor:pointer">Clear</button></form></nav>
          <div class="s-wrap">#{body}</div>
          HTML
      end

      private def self.index(ctx : Context) : String
        filter = ctx.request.query_params["q"]?
        list = Profiler.profiles
        list = list.select { |p| p.path.includes?(filter) || p.handler.includes?(filter) } if filter && !filter.empty?
        rows = list.map do |p|
          badge = p.status >= 500 ? "err" : p.status >= 400 ? "warn" : "ok"
          %(<tr><td><a href="#{Middleware::PREFIX}/#{p.token}" class="mono">#{p.token}</a></td><td><span class="s-badge #{badge}">#{p.status}</span></td><td class="mono">#{HTML.escape(p.method)}</td><td class="mono">#{HTML.escape(p.url)}</td><td class="s-muted">#{HTML.escape(p.handler)}</td><td>#{p.duration_ms.round(1)} ms</td><td>#{p.queries.size}</td><td class="s-muted">#{p.started_at.to_local.to_s("%H:%M:%S")}</td></tr>)
        end.join
        <<-HTML
          <div style="display:flex;justify-content:space-between;align-items:center"><h1 class="s-title">Requests</h1>
          <form><input class="s-input" name="q" placeholder="Filter path or handler" value="#{HTML.escape(filter || "")}"></form></div>
          <div class="s-card"><table class="s-table"><thead><tr><th>Token</th><th>Status</th><th>Method</th><th>URL</th><th>Handler</th><th>Time</th><th>Queries</th><th>At</th></tr></thead>
          <tbody>#{rows.empty? ? %(<tr><td colspan="8" class="s-muted">No requests recorded yet.</td></tr>) : rows}</tbody></table></div>
          HTML
      end

      private def self.show(p : Profile) : String
        slow = Silth.config.int("profiler.slow_query_ms", 100)
        dupes = p.queries.group_by(&.sql).select { |_, v| v.size > 1 }.keys.to_set
        queries = p.queries.map_with_index do |q, i|
          flags = String.build do |io|
            io << %( <span class="s-badge warn">slow</span>) if q.ms > slow
            io << %( <span class="s-badge info">duplicate</span>) if dupes.includes?(q.sql)
          end
          %(<tr><td class="s-muted">#{i + 1}</td><td><div class="s-sql">#{highlight_sql(q.sql)}</div>#{q.args.empty? ? "" : %(<div class="s-muted mono">[#{HTML.escape(q.args.join(", "))}]</div>)}</td><td>#{q.ms.round(2)} ms#{flags}</td><td class="s-muted">#{q.rows} rows</td></tr>)
        end.join
        logs = p.logs.map do |l|
          cls = l.level.in?("error", "fatal") ? "s-err" : l.level == "warn" ? "s-warn" : "s-muted"
          %(<tr><td class="#{cls} mono">#{l.level}</td><td class="s-muted mono">#{HTML.escape(l.source)}</td><td>#{HTML.escape(l.message)}</td></tr>)
        end.join
        entries = p.entries.map { |e| %(<tr><td><span class="s-badge">#{e.kind}</span></td><td class="mono">#{HTML.escape(e.label)}</td><td class="s-muted">#{HTML.escape(e.detail)}</td><td>#{e.ms.try { |m| "#{m.round(1)} ms" }}</td></tr>) }.join
        exceptions = p.exceptions.map { |(klass, msg, trace)| %(<div class="s-card"><div class="s-error-class">#{HTML.escape(klass)}</div><p>#{HTML.escape(msg)}</p><pre class="s-muted mono">#{HTML.escape(trace.join('\n'))}</pre></div>) }.join
        db_pct = p.duration_ms > 0 ? (p.query_ms / p.duration_ms * 100).clamp(0, 100) : 0
        <<-HTML
          <div class="s-card">
            <div class="s-error-class" style="color:var(--soul)">#{HTML.escape(p.handler)}</div>
            <h1 class="s-title mono" style="font-size:20px">#{HTML.escape(p.method)} #{HTML.escape(p.url)}</h1>
            <p class="s-sub">Profiled #{p.started_at.to_local.to_s("%Y-%m-%d %H:%M:%S")} · token #{p.token} · route #{HTML.escape(p.route)} · #{HTML.escape(p.ip)}</p>
            <div class="s-grid" style="margin-top:14px">
              <div class="s-stat"><b class="#{p.status >= 500 ? "s-err" : p.status >= 400 ? "s-warn" : "s-ok"}">#{p.status}</b><span>Status</span></div>
              <div class="s-stat"><b>#{p.duration_ms.round(1)} ms</b><span>Total time</span></div>
              <div class="s-stat"><b>#{p.queries.size} · #{p.query_ms.round(1)} ms</b><span>Database</span></div>
              <div class="s-stat"><b>#{p.logs.size}</b><span>Log entries</span></div>
              <div class="s-stat"><b>#{p.memory_kb} KB</b><span>Heap delta</span></div>
              <div class="s-stat"><b>#{HTML.escape(p.user || "guest")}</b><span>User</span></div>
            </div>
            <div id="timeline" style="margin-top:16px"><div class="s-muted" style="margin-bottom:6px">Database share of request time · #{db_pct.round(0)}%</div><div class="s-bar"><i style="width:#{db_pct.round(1)}%"></i></div></div>
          </div>
          #{exceptions}
          <div class="s-card" id="queries"><h3 style="margin-top:0">Queries <span class="s-muted">(#{p.queries.size}, #{dupes.size} duplicated)</span></h3><table class="s-table"><tbody>#{queries.empty? ? %(<tr><td class="s-muted">No queries.</td></tr>) : queries}</tbody></table></div>
          <div class="s-card" id="logs"><h3 style="margin-top:0">Logs</h3><table class="s-table"><tbody>#{logs.empty? ? %(<tr><td class="s-muted">No logs.</td></tr>) : logs}</tbody></table></div>
          <div class="s-card" id="events"><h3 style="margin-top:0">Events · cache · mails · jobs · HTTP</h3><table class="s-table"><tbody>#{entries.empty? ? %(<tr><td class="s-muted">Nothing recorded.</td></tr>) : entries}</tbody></table></div>
          <div class="s-card" id="request"><h3 style="margin-top:0">Request</h3>#{kv(p.params, "Params")}#{kv(p.session, "Session")}#{kv(p.request_headers, "Request headers")}#{kv(p.response_headers, "Response headers")}</div>
          HTML
      end

      private def self.activity : String
        rows = Profiler.background.map { |e| %(<tr><td><span class="s-badge">#{e.kind}</span></td><td class="mono">#{HTML.escape(e.label)}</td><td class="s-muted">#{HTML.escape(e.detail)}</td><td class="s-muted">#{e.at.to_local.to_s("%H:%M:%S")}</td></tr>) }.join
        failures = Queue.recent_failures.map { |f| %(<tr><td class="mono">#{HTML.escape(f[:job])}</td><td class="s-muted">#{HTML.escape(f[:queue])}</td><td class="s-err">#{HTML.escape(f[:error])}</td><td class="s-muted">#{f[:at].to_local.to_s("%H:%M:%S")}</td></tr>) }.join
        <<-HTML
          <h1 class="s-title">Activity</h1><p class="s-sub">Jobs, mails, events, warnings and exceptions happening outside HTTP requests (workers, scheduler, fibers).</p>
          <div class="s-card"><table class="s-table"><tbody>#{rows.empty? ? %(<tr><td class="s-muted">Nothing yet.</td></tr>) : rows}</tbody></table></div>
          <div class="s-card"><h3 style="margin-top:0">Failed jobs</h3><table class="s-table"><tbody>#{failures.empty? ? %(<tr><td class="s-muted">No failures. </td></tr>) : failures}</tbody></table></div>
          HTML
      end

      private def self.routes : String
        rows = Silth.router.routes.map do |r|
          %(<tr><td><span class="s-badge info">#{r.method}</span></td><td class="mono">#{HTML.escape(r.path)}</td><td class="s-muted mono">#{HTML.escape(r.name || "")}</td><td class="mono">#{HTML.escape(r.handler_name)}</td><td class="s-muted">#{r.group || "-"}#{r.middleware.empty? ? "" : " + " + r.middleware.map(&.name).join(", ")}</td></tr>)
        end.join
        %(<h1 class="s-title">Routes</h1><div class="s-card"><table class="s-table"><thead><tr><th>Verb</th><th>Path</th><th>Name</th><th>Handler</th><th>Middleware</th></tr></thead><tbody>#{rows}</tbody></table></div>)
      end

      private def self.schedule : String
        rows = Silth.scheduler.tasks.map do |t|
          %(<tr><td class="mono">#{HTML.escape(t.name)}</td><td class="mono">#{t.cron.expression}</td><td class="s-muted">#{t.location.name}</td><td>#{t.next_run.to_local.to_s("%Y-%m-%d %H:%M")}</td><td class="s-muted">#{t.last_run.try(&.to_local.to_s("%H:%M:%S")) || "never"} #{t.last_status}</td></tr>)
        end.join
        %(<h1 class="s-title">Scheduled tasks</h1><div class="s-card"><table class="s-table"><thead><tr><th>Task</th><th>Cron</th><th>Zone</th><th>Next run</th><th>Last run</th></tr></thead><tbody>#{rows.empty? ? %(<tr><td class="s-muted">No tasks. Define them with Silth.schedule.</td></tr>) : rows}</tbody></table></div>)
      end

      private def self.workflows : String
        list = Workflow.definitions.values
        return %(<h1 class="s-title">Workflows</h1><div class="s-card s-muted">No workflow defined (config/workflows.yml or Silth::Workflow.define).</div>) if list.empty?
        cards = list.map do |d|
          %(<div class="s-card"><h3 style="margin-top:0">#{HTML.escape(d.name)} <span class="s-badge">#{d.type}</span></h3>#{d.to_svg}<details><summary class="s-muted">Mermaid</summary><pre class="mono">#{HTML.escape(d.to_mermaid)}</pre></details></div>)
        end.join
        %(<h1 class="s-title">Workflows</h1>#{cards})
      end

      private def self.kv(hash : Hash(String, String), title : String) : String
        return "" if hash.empty?
        rows = hash.map { |k, v| %(<tr><td>#{HTML.escape(k)}</td><td><code>#{HTML.escape(v)}</code></td></tr>) }.join
        %(<h4 class="s-muted">#{title}</h4><table class="s-table s-kv">#{rows}</table>)
      end

      private def self.highlight_sql(sql : String) : String
        HTML.escape(sql).gsub(/\b(SELECT|FROM|WHERE|AND|OR|INSERT|INTO|VALUES|UPDATE|SET|DELETE|ORDER BY|GROUP BY|LIMIT|OFFSET|JOIN|LEFT JOIN|INNER JOIN|ON|RETURNING|COUNT|AS|IN|IS|NULL|NOT|DISTINCT|BEGIN|COMMIT|ROLLBACK|CREATE|TABLE|INDEX|WITH)\b/) { |m| %(<span class="kw">#{m}</span>) }
      end
    end
  end
end
