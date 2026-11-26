module Silth
  module Profiler
    # The `/_silth/profiler` web UI: a sidebar (sections and recent requests)
    # and, for each request, a timeline plus queries, logs, translations,
    # events and request data panels (`?panel=`).
    module Dashboard
      record Page, title : String, content : String, heading : String? = nil, crumb : String = "", actions : String = "", status : Int32 = 200

      PANELS = {"timeline" => "Timeline", "queries" => "Queries", "logs" => "Logs", "translations" => "Translations",
                "events" => "Events", "request" => "Request", "exceptions" => "Exceptions"}
      LEVELS = {"debug" => {"debug", "trace"}, "info" => {"info", "notice"}, "warn" => {"warn", "warn"}, "error" => {"error", "fatal"}}

      def self.serve(ctx : Context) : Nil
        rest = ctx.path.lchop(Middleware::PREFIX).strip('/')
        if ctx.request.method == "POST" && rest == "clear"
          Profiler.clear
          return ctx.redirect(Middleware::PREFIX)
        end
        return MailViewer.serve_raw(ctx, rest) if MailViewer.raw?(rest)
        query = ctx.request.query_params
        current = nil
        page = case rest
               when ""                      then index(query["q"]?)
               when "activity"              then activity
               when "routes"                then routes
               when "schedule"              then schedule
               when "workflows"             then workflows
               when "mails"                 then Page.new("Mails", MailViewer.index)
               when .starts_with?("mails/") then Page.new("Mail", MailViewer.show(rest), crumb: crumb("mails", "Mails"))
               else
                 if current = Profiler.find(rest)
                   show(current, query["panel"]? || "timeline", query["level"]?)
                 else
                   Page.new("Profile not found", %(<div class="s-card s-empty">Profile <code>#{HTML.escape(rest)}</code> expired or never existed. The profiler keeps the last #{Silth.config.int("profiler.keep", 200)} requests in memory.</div>), crumb: crumb("", "Requests"), status: 404)
                 end
               end
        section = rest.starts_with?("mails") ? "mails" : current || page.status == 404 ? "" : rest
        ctx.html(Brand.page("#{page.title} · Silth profiler", layout(section, page, current), ctx.csp_nonce), page.status)
      end

      private def self.layout(section : String, page : Page, current : Profile?) : String
        profiles = Profiler.profiles
        sections = [{"", "Requests", profiles.size}, {"activity", "Activity", Profiler.background.size}, {"mails", "Mails", MailViewer.count},
                    {"routes", "Routes", Silth.router.routes.size}, {"schedule", "Schedule", Silth.scheduler.tasks.size},
                    {"workflows", "Workflows", Workflow.definitions.size}]
        nav = sections.map do |(path, name, count)|
          %(<a href="#{url(path)}" class="#{section == path ? "active" : ""}">#{name}<span class="n">#{count}</span></a>)
        end.join
        recent = profiles.first(15).map do |p|
          active = current.try(&.token) == p.token ? "active" : ""
          %(<a href="#{url(p.token)}" class="#{active}" title="#{HTML.escape("#{p.method} #{p.url} · #{p.status} · #{Timeline.format_ms(p.duration_ms)} ms")}"><span class="s-dot #{p.status_class}"></span><span class="s-muted">#{HTML.escape(p.method)}</span><span>#{HTML.escape(p.path)}</span></a>)
        end.join
        <<-HTML
          <div class="s-app">
            <aside class="s-side">
              <a class="s-brand" href="#{Middleware::PREFIX}">#{Brand::LOGO_SVG} silth <small>profiler</small></a>
              <div><p class="s-side-title">Inspect</p><nav>#{nav}</nav></div>
              <div class="s-recent"><p class="s-side-title">Recent requests</p>#{recent.empty? ? %(<p class="s-muted" style="padding:0 8px;font-size:12px">Nothing yet.</p>) : recent}</div>
              <footer><span>v#{VERSION} · #{HTML.escape(Silth.env)}</span>
                <form method="post" action="#{Middleware::PREFIX}/clear"><button class="s-link" type="submit">Clear</button></form></footer>
            </aside>
            <main class="s-main">
              <header class="s-top">#{page.crumb}<h1>#{page.heading || HTML.escape(page.title)}</h1><div class="s-actions">#{page.actions}</div></header>
              <div class="s-content">#{page.content}</div>
            </main>
          </div>
          HTML
      end

      private def self.index(filter : String?) : Page
        all = Profiler.profiles
        filter = filter.presence
        list = filter ? all.select { |p| p.url.includes?(filter) || p.handler.includes?(filter) || p.status.to_s == filter } : all
        times = all.map(&.duration_ms).sort
        stats = String.build do |io|
          io << %(<div class="s-grid">)
          stat(io, all.size.to_s, "Requests")
          stat(io, times.empty? ? "-" : "#{Timeline.format_ms(times[times.size // 2])} ms", "Median time")
          stat(io, times.empty? ? "-" : "#{Timeline.format_ms(times.last)} ms", "Slowest")
          stat(io, all.count { |p| p.status >= 500 }.to_s, "Server errors", all.any? { |p| p.status >= 500 } ? "s-err" : "")
          stat(io, all.empty? ? "-" : (all.sum(&.queries.size) / all.size).round(1).to_s, "Queries per request")
          io << "</div>"
        end
        rows = list.map do |p|
          warn = p.duplicated_queries > 0 || !p.missing_translations.empty? || p.log_count("warn", "error", "fatal") > 0
          %(<tr><td><span class="s-badge #{p.status_class}">#{p.status}</span></td><td class="mono s-muted">#{HTML.escape(p.method)}</td><td class="mono"><a class="row-link" href="#{url(p.token)}">#{HTML.escape(p.url)}</a>#{warn ? %( <span class="s-dot warn" title="Warnings: logs, duplicated queries or missing translations"></span>) : ""}</td><td class="s-muted">#{HTML.escape(p.handler)}</td><td class="num">#{Timeline.format_ms(p.duration_ms)} ms</td><td class="num">#{p.queries.size}</td><td class="num s-muted">#{p.started_at.to_local.to_s("%H:%M:%S")}</td><td class="num"><a class="mono" href="#{url(p.token)}">#{p.token}</a></td></tr>)
        end.join
        content = <<-HTML
          #{stats}
          <div class="s-card" style="padding:0"><table class="s-table"><thead><tr><th>Status</th><th>Method</th><th>URL</th><th>Handler</th><th class="num">Time</th><th class="num">Queries</th><th class="num">At</th><th class="num">Profile</th></tr></thead>
          <tbody>#{rows.empty? ? %(<tr><td colspan="8" class="s-empty">#{filter ? "No request matches this filter." : "No request recorded yet. Open a page of your app."}</td></tr>) : rows}</tbody></table></div>
          HTML
        actions = %(<form><input class="s-input" name="q" placeholder="Filter URL, handler or status" value="#{HTML.escape(filter || "")}" aria-label="Filter requests"></form>)
        Page.new("Requests", content, actions: actions)
      end

      private def self.show(p : Profile, panel : String, level : String?) : Page
        panel = "timeline" unless PANELS.has_key?(panel)
        counts = {"queries" => p.queries.size, "logs" => p.logs.size, "translations" => p.translations.size,
                  "events" => p.entries.size, "exceptions" => p.exceptions.size}
        tabs = PANELS.compact_map do |key, name|
          next if key == "exceptions" && p.exceptions.empty?
          n = counts[key]?
          alert = (key == "translations" && !p.missing_translations.empty?) || key == "exceptions" ? " s-warn" : ""
          %(<a href="#{url(p.token)}?panel=#{key}" class="#{panel == key ? "active" : ""}">#{name}#{n ? %(<span class="n#{alert}">#{n}</span>) : ""}</a>)
        end.join
        body = case panel
               when "queries"      then queries_panel(p)
               when "logs"         then logs_panel(p, level)
               when "translations" then translations_panel(p)
               when "events"       then events_panel(p)
               when "request"      then request_panel(p)
               when "exceptions"   then exceptions_panel(p)
               else                     Timeline.render(p)
               end
        stats = String.build do |io|
          io << %(<div class="s-grid">)
          stat(io, p.status.to_s, HTTP::Status.new(p.status).description || "Status", "s-#{p.status_class}")
          stat(io, "#{Timeline.format_ms(p.duration_ms)} ms", "Total")
          p.before_action_ms.try { |v| stat(io, "#{Timeline.format_ms(v)} ms", "Before the action") }
          p.action_ms.try { |v| stat(io, "#{Timeline.format_ms(v)} ms", "Action") }
          stat(io, "#{Timeline.format_ms(p.view_ms)} ms", "Templates")
          stat(io, "#{Timeline.format_ms(p.query_ms)} ms", "Database, #{p.queries.size} quer#{p.queries.size == 1 ? "y" : "ies"}", p.duplicated_queries > 0 ? "s-warn" : "")
          stat(io, "#{p.memory_kb} KB", "Heap delta")
          stat(io, p.user || "guest", "User")
          io << "</div>"
        end
        content = <<-HTML
          <p class="s-sub mono">#{HTML.escape(p.handler)} · route #{HTML.escape(p.route)} · #{p.started_at.to_local.to_s("%Y-%m-%d %H:%M:%S")} · #{HTML.escape(p.ip)} · #{p.token}</p>
          #{stats}
          <nav class="s-tabs">#{tabs}</nav>
          #{body}
          HTML
        heading = %(<span class="s-badge #{p.status_class}">#{p.status}</span> <span class="mono">#{HTML.escape(p.method)} #{HTML.escape(p.url)}</span>)
        actions = p.method == "GET" ? %(<a class="s-btn" href="#{HTML.escape(p.url)}" target="_blank" rel="noopener">Open page</a>) : ""
        Page.new("#{p.method} #{p.url}", content, heading: heading, crumb: crumb("", "Requests"), actions: actions)
      end

      private def self.queries_panel(p : Profile) : String
        return empty("No query during this request.") if p.queries.empty?
        slow = Profiler.slow_query_ms
        repeats = p.repeated_queries
        repeated = repeats.map { |r| {r.sql, r.source} }.to_set
        dupes = repeats.map do |r|
          from = r.source ? %(<div class="s-from">from #{Editor.link(r.source.not_nil!)}</div>) : ""
          %(<tr><td class="num"><span class="s-badge warn">×#{r.count}</span></td><td><div class="s-sql">#{highlight_sql(r.sql)}</div>#{from}</td><td class="num">#{Timeline.format_ms(r.ms)} ms</td></tr>)
        end.join
        rows = p.queries.map_with_index do |q, i|
          flags = String.build do |io|
            io << %( <span class="s-badge warn">slow</span>) if q.ms > slow
            io << %( <span class="s-badge info">repeated</span>) if repeated.includes?({q.sql, q.source})
          end
          args = q.args.empty? ? "" : %(<div class="s-muted mono" style="margin-top:4px">[#{HTML.escape(q.args.join(", "))}]</div>)
          source = q.source.try { |s| Editor.link(s) } || %(<span class="s-muted">-</span>)
          %(<tr><td class="num s-muted">#{i + 1}</td><td class="num s-muted">+#{Timeline.format_ms(q.start_ms)}</td><td><div class="s-sql">#{highlight_sql(q.sql)}</div>#{args}</td><td class="s-src-cell">#{source}</td><td class="num s-muted">#{q.rows}</td><td class="num">#{Timeline.format_ms(q.ms)} ms#{flags}</td></tr>)
        end.join
        String.build do |io|
          io << %(<p class="s-sub">#{p.queries.size} queries in #{Timeline.format_ms(p.query_ms)} ms on #{p.queries.map(&.connection).uniq.join(", ")}.</p>)
          unless repeats.empty?
            io << %(<div class="s-card"><h3 class="s-warn">Same statement from the same line, several times (possible N+1)</h3><table class="s-table"><tbody>#{dupes}</tbody></table>)
            io << %(<p class="s-muted" style="margin:10px 0 0">A query inside a loop: preload the association (<code>.includes(:author)</code>), load the rows in one query, or cache the result.</p></div>)
          end
          io << %(<div class="s-card" style="padding:0"><table class="s-table"><thead><tr><th class="num">#</th><th class="num">At</th><th>Statement</th><th>Source</th><th class="num">Rows</th><th class="num">Time</th></tr></thead><tbody>#{rows}</tbody></table></div>)
          io << %(<p class="s-muted">No source? Queries are traced back to your code from the backtrace, which needs a build with debug information (the default of <code>silth serve</code>). Set <code>profiler.query_sources: false</code> to turn it off.</p>) if p.queries.all? { |q| q.source.nil? }
        end
      end

      private def self.logs_panel(p : Profile, level : String?) : String
        return empty("No log line during this request.") if p.logs.empty?
        level = nil unless level && LEVELS.has_key?(level)
        filters = String.build do |io|
          io << %(<a href="#{url(p.token)}?panel=logs" class="s-badge#{level ? "" : " info"}">all #{p.logs.size}</a> )
          LEVELS.each do |name, levels|
            io << %(<a href="#{url(p.token)}?panel=logs&amp;level=#{name}" class="s-badge#{level == name ? " info" : ""}">#{name} #{p.log_count(*levels)}</a> )
          end
        end
        lines = level ? p.logs.select { |l| l.level.in?(LEVELS[level]) } : p.logs
        rows = lines.map do |l|
          badge = l.level.in?("error", "fatal") ? "err" : l.level == "warn" ? "warn" : l.level == "info" ? "info" : ""
          %(<tr><td class="num s-muted">+#{Timeline.format_ms(l.offset_ms)}</td><td><span class="s-badge #{badge}">#{l.level}</span></td><td class="s-muted mono">#{HTML.escape(l.source)}</td><td style="white-space:pre-wrap">#{HTML.escape(l.message)}</td></tr>)
        end.join
        <<-HTML
          <p style="display:flex;gap:6px;flex-wrap:wrap;margin:0 0 14px">#{filters}</p>
          <div class="s-card" style="padding:0"><table class="s-table"><thead><tr><th class="num">At</th><th>Level</th><th>Source</th><th>Message</th></tr></thead>
          <tbody>#{rows.empty? ? %(<tr><td colspan="4" class="s-empty">No #{level} line.</td></tr>) : rows}</tbody></table></div>
          HTML
      end

      private def self.translations_panel(p : Profile) : String
        return empty("No translation lookup during this request.") if p.translations.empty?
        order = {"missing" => 0, "fallback" => 1, "found" => 2}
        entries = p.translations.values.sort_by { |t| {order.fetch(t.status, 3), t.key} }
        missing = p.missing_translations
        rows = entries.map do |t|
          badge = t.missing? ? "warn" : t.status == "fallback" ? "info" : "ok"
          %(<tr><td><span class="s-badge #{badge}">#{t.status}</span></td><td class="mono">#{HTML.escape(t.key)}</td><td class="mono s-muted">#{HTML.escape(t.locale)}</td><td class="num">#{t.count}</td></tr>)
        end.join
        hint = missing.empty? ? "" : %(<div class="s-card"><h3 class="s-warn">#{missing.size} missing key#{missing.size > 1 ? "s" : ""}</h3><p class="s-muted" style="margin:0">Add #{missing.map(&.locale).uniq.map { |l| "<code>config/locales/#{HTML.escape(l)}.yml</code>" }.join(", ")} entries for them; the key itself is displayed until then.</p></div>)
        <<-HTML
          #{hint}
          <div class="s-card" style="padding:0"><table class="s-table"><thead><tr><th>Status</th><th>Key</th><th>Locale</th><th class="num">Lookups</th></tr></thead><tbody>#{rows}</tbody></table></div>
          HTML
      end

      private def self.events_panel(p : Profile) : String
        return empty("No event, cache access, mail, job or HTTP call during this request.") if p.entries.empty?
        rows = p.entries.map do |e|
          %(<tr><td class="num s-muted">#{e.offset_ms.try { |o| "+" + Timeline.format_ms(o) }}</td><td><span class="s-badge">#{e.kind}</span></td><td class="mono">#{HTML.escape(e.label)}</td><td class="s-muted">#{HTML.escape(e.detail)}</td><td class="num">#{e.ms.try { |m| "#{Timeline.format_ms(m)} ms" }}</td></tr>)
        end.join
        %(<div class="s-card" style="padding:0"><table class="s-table"><thead><tr><th class="num">At</th><th>Kind</th><th>Name</th><th>Detail</th><th class="num">Time</th></tr></thead><tbody>#{rows}</tbody></table></div>)
      end

      private def self.request_panel(p : Profile) : String
        info = {"Method" => p.method, "URL" => p.url, "Route" => p.route, "Handler" => p.handler, "Status" => p.status.to_s,
                "Client IP" => p.ip, "Locale" => p.locale, "User" => p.user || "guest", "Profile" => p.token}
        kv(info, "Request") + kv(p.params, "Params") + kv(p.session, "Session") +
          kv(p.request_headers, "Request headers") + kv(p.response_headers, "Response headers")
      end

      private def self.exceptions_panel(p : Profile) : String
        return empty("No exception.") if p.exceptions.empty?
        p.exceptions.map do |e|
          frames = e.backtrace.map do |frame|
            if (m = DebugPage::FRAME.match(frame)) && DebugPage.app_frame?(frame, Dir.current)
              %(<div class="s-frame app"><div class="loc">#{Editor.link(m["file"], m["line"].to_i)}</div><div class="fn">#{HTML.escape(m["fn"])}</div></div>)
            else
              %(<div class="s-frame"><div class="fn">#{HTML.escape(frame)}</div></div>)
            end
          end.join
          %(<div class="s-card"><div class="s-error-class">#{HTML.escape(e.name)}</div><p>#{HTML.escape(e.message)}</p>#{frames}</div>)
        end.join
      end

      private def self.activity : Page
        rows = Profiler.background.map { |e| %(<tr><td class="num s-muted">#{e.at.to_local.to_s("%H:%M:%S")}</td><td><span class="s-badge">#{e.kind}</span></td><td class="mono">#{HTML.escape(e.label)}</td><td class="s-muted">#{HTML.escape(e.detail)}</td></tr>) }.join
        failures = Queue.recent_failures.map { |f| %(<tr><td class="num s-muted">#{f[:at].to_local.to_s("%H:%M:%S")}</td><td class="mono">#{HTML.escape(f[:job])}</td><td class="s-muted">#{HTML.escape(f[:queue])}</td><td class="s-err">#{HTML.escape(f[:error])}</td></tr>) }.join
        content = <<-HTML
          <p class="s-sub">Jobs, mails, events, warnings and exceptions that happened outside HTTP requests (workers, scheduler, background fibers).</p>
          <div class="s-card" style="padding:0"><table class="s-table"><thead><tr><th class="num">At</th><th>Kind</th><th>Name</th><th>Detail</th></tr></thead><tbody>#{rows.empty? ? %(<tr><td colspan="4" class="s-empty">Nothing yet.</td></tr>) : rows}</tbody></table></div>
          <div class="s-card"><h3>Failed jobs</h3><table class="s-table"><tbody>#{failures.empty? ? %(<tr><td class="s-muted">No failure.</td></tr>) : failures}</tbody></table></div>
          HTML
        Page.new("Activity", content)
      end

      private def self.routes : Page
        rows = Silth.router.routes.map do |r|
          %(<tr><td><span class="s-badge info">#{r.method}</span></td><td class="mono">#{HTML.escape(r.path)}</td><td class="s-muted mono">#{HTML.escape(r.name || "")}</td><td class="mono">#{HTML.escape(r.handler_name)}</td><td class="s-muted">#{r.group || "-"}#{r.middleware.empty? ? "" : " + " + r.middleware.map(&.name).join(", ")}</td></tr>)
        end.join
        Page.new("Routes", %(<div class="s-card" style="padding:0"><table class="s-table"><thead><tr><th>Verb</th><th>Path</th><th>Name</th><th>Handler</th><th>Middleware</th></tr></thead><tbody>#{rows.empty? ? %(<tr><td colspan="5" class="s-empty">No route.</td></tr>) : rows}</tbody></table></div>))
      end

      private def self.schedule : Page
        rows = Silth.scheduler.tasks.map do |t|
          %(<tr><td class="mono">#{HTML.escape(t.name)}</td><td class="mono">#{t.cron.expression}</td><td class="s-muted">#{t.location.name}</td><td>#{t.next_run.to_local.to_s("%Y-%m-%d %H:%M")}</td><td class="s-muted">#{t.last_run.try(&.to_local.to_s("%H:%M:%S")) || "never"} #{t.last_status}</td></tr>)
        end.join
        Page.new("Scheduled tasks", %(<div class="s-card" style="padding:0"><table class="s-table"><thead><tr><th>Task</th><th>Cron</th><th>Zone</th><th>Next run</th><th>Last run</th></tr></thead><tbody>#{rows.empty? ? %(<tr><td colspan="5" class="s-empty">No task. Define them with <code>Silth.schedule</code>.</td></tr>) : rows}</tbody></table></div>))
      end

      private def self.workflows : Page
        list = Workflow.definitions.values
        return Page.new("Workflows", empty("No workflow defined (config/workflows.yml or Silth::Workflow.define).")) if list.empty?
        cards = list.map do |d|
          %(<div class="s-card"><h3>#{HTML.escape(d.name)} <span class="s-badge">#{d.type}</span></h3>#{d.to_svg}<details class="s-more"><summary>Mermaid</summary><pre class="mono">#{HTML.escape(d.to_mermaid)}</pre></details></div>)
        end.join
        Page.new("Workflows", cards)
      end

      private def self.stat(io : IO, value : String, label : String, css : String = "") : Nil
        io << %(<div class="s-stat"><b class="#{css}">) << HTML.escape(value) << "</b><span>" << HTML.escape(label) << "</span></div>"
      end

      private def self.kv(hash : Hash(String, String), title : String) : String
        rows = hash.map { |k, v| %(<tr><td>#{HTML.escape(k)}</td><td><code>#{HTML.escape(v)}</code></td></tr>) }.join
        %(<div class="s-card"><h3>#{title}</h3>#{hash.empty? ? %(<p class="s-muted" style="margin:0">Empty.</p>) : %(<table class="s-table s-kv">#{rows}</table>)}</div>)
      end

      private def self.empty(message : String) : String
        %(<div class="s-card s-empty">#{message}</div>)
      end

      private def self.url(path : String) : String
        path.empty? ? Middleware::PREFIX : "#{Middleware::PREFIX}/#{path}"
      end

      private def self.crumb(path : String, name : String) : String
        %(<span class="s-crumb"><a href="#{url(path)}">#{name}</a> /</span>)
      end

      private def self.highlight_sql(sql : String) : String
        HTML.escape(sql).gsub(/\b(SELECT|FROM|WHERE|AND|OR|INSERT|INTO|VALUES|UPDATE|SET|DELETE|ORDER BY|GROUP BY|LIMIT|OFFSET|JOIN|LEFT JOIN|INNER JOIN|ON|RETURNING|COUNT|AS|IN|IS|NULL|NOT|DISTINCT|BEGIN|COMMIT|ROLLBACK|CREATE|TABLE|INDEX|WITH)\b/) { |m| %(<span class="kw">#{m}</span>) }
      end
    end
  end
end
