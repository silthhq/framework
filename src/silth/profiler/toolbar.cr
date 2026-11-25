module Silth
  module Profiler
    # The bar injected at the bottom of every HTML page in development.
    #
    # Each item shows a summary; hovering (or focusing) it opens a panel with
    # the details, and every link opens the full profile in a new tab so the
    # page under test stays as it is. The bar folds into an icon at the bottom
    # right (remembered in localStorage).
    module Toolbar
      ICONS = {
        "time"   => %(<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>),
        "db"     => %(<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v14c0 1.7 3.6 3 8 3s8-1.3 8-3V5"/><path d="M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>),
        "logs"   => %(<path d="M9 6h12M9 12h12M9 18h12M4 6h.01M4 12h.01M4 18h.01"/>),
        "i18n"   => %(<path d="M4 5h8M8 3v2M6 5c0 4 2.5 7 6 8M10 5c-.5 4-3 7-6 8"/><path d="M13 21l4-9 4 9M14.5 18h5"/>),
        "events" => %(<path d="M13 2 4 14h7l-1 8 9-12h-7z"/>),
        "error"  => %(<path d="M12 3 2 21h20z"/><path d="M12 10v5M12 18h.01"/>),
        "user"   => %(<circle cx="12" cy="8" r="4"/><path d="M4 21c0-4 3.6-6 8-6s8 2 8 6"/>),
        "hide"   => %(<path d="m6 9 6 6 6-6"/>),
      }

      def self.render(p : Profile, nonce : String?) : String
        n = nonce ? %( nonce="#{nonce}") : ""
        base = "#{Middleware::PREFIX}/#{p.token}"
        String.build do |io|
          io << %(<div id="silth-toolbar" data-token="#{p.token}"><style#{n}>) << CSS << %(</style>)
          io << %(<div class="stb-bar" role="toolbar" aria-label="Silth profiler">)
          io << %(<a class="stb-logo" href="#{Middleware::PREFIX}" target="_blank" rel="noopener" title="Open the profiler">#{Brand::LOGO_SVG}</a>)
          request_item(io, p, base)
          time_item(io, p, base)
          db_item(io, p, base)
          logs_item(io, p, base)
          i18n_item(io, p, base) unless p.translations.empty?
          events_item(io, p, base) unless p.entries.empty?
          exceptions_item(io, p, base) unless p.exceptions.empty?
          io << %(<div class="stb-fill"></div>)
          user_item(io, p, base)
          version_item(io)
          io << %(<button class="stb-hide" type="button" title="Fold the toolbar" aria-label="Fold the toolbar">#{icon("hide")}</button></div>)
          io << %(<button class="stb-fab" type="button" title="Show the Silth toolbar" aria-label="Show the Silth toolbar">#{Brand::LOGO_SVG}<i class="stb-dot #{p.status_class}"></i></button>)
          io << %(<script#{n}>) << SCRIPT << %(</script></div>)
        end
      end

      private def self.request_item(io, p : Profile, base : String) : Nil
        item(io, "#{base}?panel=request", "", "Request") do |label, pop|
          label << %(<b class="stb-code #{p.status_class}">#{p.status}</b><span class="stb-lbl">#{HTML.escape(p.method)} #{HTML.escape(short(p.handler == "-" ? p.path : p.handler, 48))}</span>)
          pop << "<h4>Request</h4>"
          kv(pop, {
            "Status"  => "#{p.status} #{HTTP::Status.new(p.status).description}",
            "URL"     => "#{p.method} #{p.url}",
            "Route"   => p.route,
            "Handler" => p.handler,
            "Locale"  => p.locale,
            "Client"  => p.ip,
          })
          pop << %(<a class="stb-more" href="#{base}" target="_blank" rel="noopener">Open profile #{p.token}</a>)
        end
      end

      private def self.time_item(io, p : Profile, base : String) : Nil
        total = p.total_ms
        item(io, "#{base}?panel=timeline", "", "Time") do |label, pop|
          label << icon("time") << %(<b>#{Timeline.format_ms(total)}</b><span class="stb-u">ms</span>)
          pop << "<h4>Time</h4>"
          rows = {"Total" => ms(total)}
          p.before_action_ms.try { |v| rows["Before the action"] = ms(v) }
          p.action_ms.try { |v| rows["Action"] = ms(v) }
          rows["Templates"] = ms(p.view_ms) if p.view_ms > 0
          rows["Database"] = "#{ms(p.query_ms)} (#{percent(p.query_ms, total)})"
          rows["Memory"] = "#{p.memory_kb} KB heap delta"
          kv(pop, rows)
          pop << %(<a class="stb-more" href="#{base}?panel=timeline" target="_blank" rel="noopener">Timeline</a>)
        end
      end

      private def self.db_item(io, p : Profile, base : String) : Nil
        slow_limit = Profiler.slow_query_ms
        dupes = p.duplicated_queries
        slow = p.slow_queries(slow_limit)
        state = slow > 0 || dupes > 0 || p.queries.size > 30 ? "warn" : ""
        item(io, "#{base}?panel=queries", state, "Database") do |label, pop|
          label << icon("db") << %(<b>#{p.queries.size}</b><span class="stb-lbl">#{ms(p.query_ms)}</span>)
          pop << "<h4>Database</h4>"
          kv(pop, {
            "Queries"    => p.queries.size.to_s,
            "Time"       => ms(p.query_ms),
            "Duplicated" => dupes.zero? ? "none" : "#{dupes} statement(s), possible N+1",
            "Slow"       => slow.zero? ? "none above #{slow_limit} ms" : "#{slow} above #{slow_limit} ms",
          })
          slowest = p.queries.sort_by { |q| -q.ms }.first(3)
          unless slowest.empty?
            pop << %(<p class="stb-sub">Slowest</p><ul class="stb-list">)
            slowest.each { |q| pop << %(<li><code>#{HTML.escape(short(q.sql, 90))}</code><span>#{ms(q.ms)}</span></li>) }
            pop << "</ul>"
          end
        end
      end

      private def self.logs_item(io, p : Profile, base : String) : Nil
        warns = p.log_count("warn")
        errors = p.log_count("error", "fatal")
        state = errors > 0 ? "err" : warns > 0 ? "warn" : ""
        item(io, "#{base}?panel=logs", state, "Logs") do |label, pop|
          label << icon("logs") << %(<b>#{p.logs.size}</b>)
          label << %(<span class="stb-lbl">#{errors > 0 ? "#{errors} error#{errors > 1 ? "s" : ""}" : "#{warns} warn"}</span>) if errors > 0 || warns > 0
          pop << "<h4>Logs</h4>"
          kv(pop, {"Debug" => p.log_count("debug", "trace").to_s, "Info" => p.log_count("info", "notice").to_s,
                   "Warning" => warns.to_s, "Error" => errors.to_s})
          notable = p.logs.select { |l| l.level.in?("warn", "error", "fatal") }.last(4)
          unless notable.empty?
            pop << %(<ul class="stb-list">)
            notable.each { |l| pop << %(<li><code class="#{l.level == "warn" ? "warn" : "err"}">#{HTML.escape(short(l.message, 90))}</code></li>) }
            pop << "</ul>"
          end
          pop << %(<a class="stb-more" href="#{base}?panel=logs" target="_blank" rel="noopener">All logs</a>)
        end
      end

      private def self.i18n_item(io, p : Profile, base : String) : Nil
        missing = p.missing_translations
        fallback = p.translations.values.count { |t| t.status == "fallback" }
        item(io, "#{base}?panel=translations", missing.empty? ? "" : "warn", "Translations") do |label, pop|
          label << icon("i18n")
          label << (missing.empty? ? %(<b>#{p.translations.size}</b>) : %(<b>#{missing.size}</b><span class="stb-lbl">missing</span>))
          pop << "<h4>Translations</h4>"
          kv(pop, {"Locale" => p.locale, "Keys" => p.translations.size.to_s, "Missing" => missing.size.to_s, "Fallback" => fallback.to_s})
          unless missing.empty?
            pop << %(<ul class="stb-list">)
            missing.first(6).each { |t| pop << %(<li><code class="warn">#{HTML.escape(t.key)}</code><span>#{HTML.escape(t.locale)}</span></li>) }
            pop << "</ul>"
          end
        end
      end

      private def self.events_item(io, p : Profile, base : String) : Nil
        item(io, "#{base}?panel=events", "", "Events", "stb-sm") do |label, pop|
          label << icon("events") << %(<b>#{p.entries.size}</b>)
          pop << "<h4>Events, cache, mails, jobs</h4>"
          kv(pop, p.entries.group_by(&.kind).transform_values(&.size.to_s))
          pop << %(<ul class="stb-list">)
          p.entries.last(5).each { |e| pop << %(<li><code>#{HTML.escape(short(e.label, 70))}</code><span>#{HTML.escape(short(e.detail, 24))}</span></li>) }
          pop << "</ul>"
        end
      end

      private def self.exceptions_item(io, p : Profile, base : String) : Nil
        item(io, "#{base}?panel=exceptions", "err", "Exceptions") do |label, pop|
          label << icon("error") << %(<b>#{p.exceptions.size}</b>)
          pop << "<h4>Exceptions</h4>"
          pop << %(<ul class="stb-list">)
          p.exceptions.each { |e| pop << %(<li><code class="err">#{HTML.escape(e.name)}</code><span>#{HTML.escape(short(e.message, 60))}</span></li>) }
          pop << "</ul>"
        end
      end

      private def self.user_item(io, p : Profile, base : String) : Nil
        item(io, "#{base}?panel=request", "", "User", "stb-opt stb-end") do |label, pop|
          label << icon("user") << %(<span class="stb-lbl">#{HTML.escape(short(p.user || "guest", 32))}</span>)
          pop << "<h4>User</h4>"
          kv(pop, {"Authenticated" => p.user ? "yes" : "no", "User" => p.user || "guest", "Session keys" => p.session.size.to_s, "Locale" => p.locale})
        end
      end

      private def self.version_item(io) : Nil
        item(io, Middleware::PREFIX, "", "Silth", "stb-opt stb-end") do |label, pop|
          label << %(<span class="stb-lbl">silth #{VERSION}</span>)
          pop << "<h4>Silth</h4>"
          kv(pop, {"Silth" => VERSION, "Crystal" => Crystal::VERSION, "Environment" => Silth.env})
          pop << %(<p class="stb-links">)
          {"" => "Requests", "/activity" => "Activity", "/mails" => "Mails", "/routes" => "Routes"}.each do |path, name|
            pop << %(<a href="#{Middleware::PREFIX}#{path}" target="_blank" rel="noopener">#{name}</a>)
          end
          pop << "</p>"
        end
      end

      private def self.item(io, href : String, state : String, title : String, extra : String = "", &) : Nil
        label = String::Builder.new
        pop = String::Builder.new
        yield label, pop
        io << %(<div class="stb-item #{extra} #{state}" tabindex="-1"><a href="#{href}" target="_blank" rel="noopener" title="#{title}">)
        io << label.to_s << %(</a><div class="stb-pop" role="tooltip">) << pop.to_s << "</div></div>"
      end

      private def self.kv(io, rows : Hash(String, String)) : Nil
        io << %(<dl class="stb-kv">)
        rows.each { |k, v| io << "<dt>" << HTML.escape(k) << "</dt><dd>" << HTML.escape(v) << "</dd>" }
        io << "</dl>"
      end

      private def self.icon(name : String) : String
        %(<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">#{ICONS[name]}</svg>)
      end

      private def self.ms(value : Float64) : String
        "#{Timeline.format_ms(value)} ms"
      end

      private def self.percent(part : Float64, total : Float64) : String
        total > 0 ? "#{(part / total * 100).clamp(0, 100).round(0).to_i}%" : "0%"
      end

      private def self.short(text : String, max : Int32) : String
        line = text.gsub(/\s+/, " ").strip
        line.size > max ? line[0, max - 1] + "…" : line
      end

      # Scoped to #silth-toolbar; resets the elements it uses so the app's CSS
      # does not leak in (SVG children are left alone: `revert` would drop their attributes).
      CSS = <<-CSS
        #silth-toolbar{all:initial;display:block;height:36px;color:#ecebf5;font:12px/1.4 Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;-webkit-font-smoothing:antialiased}
        #silth-toolbar :where(div,a,b,span,i,p,h4,dl,dt,dd,ul,li,code,button){all:revert;box-sizing:border-box;font:inherit;color:inherit}
        #silth-toolbar svg{display:block;flex:none}
        #silth-toolbar .stb-bar{position:fixed;left:0;right:0;bottom:0;z-index:2147483000;display:flex;align-items:stretch;height:36px;background:#0b0d13;border-top:1px solid #1f2330}
        #silth-toolbar .stb-logo{display:flex;align-items:center;padding:0 12px;color:#ecebf5;border-right:1px solid #1f2330}
        #silth-toolbar .stb-logo svg{width:18px;height:18px}
        #silth-toolbar .stb-item{position:relative;display:flex;border-right:1px solid #1f2330;outline:none}
        #silth-toolbar .stb-item>a{display:flex;align-items:center;gap:7px;padding:0 12px;color:#b9bdd0;text-decoration:none;white-space:nowrap}
        #silth-toolbar .stb-item>a:focus-visible{outline:2px solid #a6dcff;outline-offset:-2px}
        #silth-toolbar .stb-item:hover>a,#silth-toolbar .stb-item:focus-within>a{background:#161a24;color:#ecebf5}
        #silth-toolbar .stb-item b{font:600 12px/1 "JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,monospace;color:#ecebf5}
        #silth-toolbar .stb-u,#silth-toolbar .stb-lbl{color:#868ba3}
        #silth-toolbar .stb-item.warn>a,#silth-toolbar .stb-item.warn b{color:#e3bb74}
        #silth-toolbar .stb-item.err>a,#silth-toolbar .stb-item.err b{color:#ff6b81}
        #silth-toolbar .stb-code{padding:2px 6px;border-radius:4px;background:#161a24;border:1px solid #2a3042}
        #silth-toolbar .stb-code.ok{color:#82dcae}#silth-toolbar .stb-code.warn{color:#e3bb74}#silth-toolbar .stb-code.err{color:#ff6b81}
        #silth-toolbar .stb-fill{flex:1;border-right:1px solid #1f2330}
        #silth-toolbar .stb-end{border-right:1px solid #1f2330}
        #silth-toolbar .stb-pop{display:none;position:absolute;left:-1px;bottom:100%;width:max-content;min-width:260px;max-width:min(460px,calc(100vw - 16px));padding:12px 14px;background:#10131b;border:1px solid #2a3042;border-radius:6px 6px 0 0;color:#b9bdd0;cursor:default}
        #silth-toolbar .stb-end .stb-pop{left:auto;right:-1px}
        #silth-toolbar .stb-item:hover .stb-pop,#silth-toolbar .stb-item:focus-within .stb-pop{display:block}
        #silth-toolbar .stb-pop h4{margin:0 0 8px;color:#ecebf5;font-weight:600;font-size:12px}
        #silth-toolbar .stb-kv{display:grid;grid-template-columns:auto 1fr;gap:3px 16px;margin:0}
        #silth-toolbar .stb-kv dt{color:#868ba3}
        #silth-toolbar .stb-kv dd{margin:0;color:#ecebf5;font-family:"JetBrains Mono",ui-monospace,Menlo,monospace;font-size:11.5px;word-break:break-all}
        #silth-toolbar .stb-sub{margin:10px 0 0;padding-top:8px;border-top:1px solid #1f2330;color:#868ba3}
        #silth-toolbar .stb-sub+.stb-list{margin-top:4px;padding-top:0;border-top:0}
        #silth-toolbar .stb-list{list-style:none;margin:10px 0 0;padding:8px 0 0;border-top:1px solid #1f2330;display:grid;gap:4px}
        #silth-toolbar .stb-list li{display:flex;justify-content:space-between;gap:12px;margin:0;min-width:0}
        #silth-toolbar .stb-list code{flex:1;min-width:0;font:11.5px/1.4 "JetBrains Mono",ui-monospace,Menlo,monospace;color:#b9bdd0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        #silth-toolbar .stb-list span{color:#868ba3;white-space:nowrap;font-size:11.5px}
        #silth-toolbar code.warn{color:#e3bb74}#silth-toolbar code.err{color:#ff6b81}
        #silth-toolbar .stb-more{display:inline-block;margin-top:10px;color:#a6dcff;text-decoration:none}
        #silth-toolbar .stb-more:hover,#silth-toolbar .stb-links a:hover{text-decoration:underline}
        #silth-toolbar .stb-links{display:flex;gap:12px;margin:10px 0 0}
        #silth-toolbar .stb-links a{color:#a6dcff;text-decoration:none}
        #silth-toolbar .stb-hide{display:flex;align-items:center;padding:0 12px;border:0;background:none;color:#868ba3;cursor:pointer}
        #silth-toolbar .stb-hide:hover{color:#ecebf5;background:#161a24}
        #silth-toolbar .stb-fab{display:none;position:fixed;right:14px;bottom:14px;z-index:2147483000;width:38px;height:38px;align-items:center;justify-content:center;padding:0;border:1px solid #2a3042;border-radius:8px;background:#0b0d13;color:#ecebf5;cursor:pointer}
        #silth-toolbar .stb-fab:hover{background:#161a24}
        #silth-toolbar .stb-fab svg{width:20px;height:20px}
        #silth-toolbar .stb-dot{position:absolute;top:6px;right:6px;width:7px;height:7px;border-radius:50%;background:#82dcae;box-shadow:0 0 0 2px #0b0d13}
        #silth-toolbar .stb-dot.warn{background:#e3bb74}#silth-toolbar .stb-dot.err{background:#ff6b81}
        #silth-toolbar.stb-min{height:0}
        #silth-toolbar.stb-min .stb-bar{display:none}
        #silth-toolbar.stb-min .stb-fab{display:flex}
        @media (max-width:900px){#silth-toolbar .stb-opt{display:none}}
        @media (max-width:640px){#silth-toolbar .stb-lbl,#silth-toolbar .stb-u,#silth-toolbar .stb-sm{display:none}#silth-toolbar .stb-item>a,#silth-toolbar .stb-logo,#silth-toolbar .stb-hide{padding:0 9px}}
        @media print{#silth-toolbar{display:none}}
        CSS

      SCRIPT = <<-JS
        (()=>{const t=document.getElementById("silth-toolbar");if(!t)return;const k="silth-toolbar";
        const fold=m=>{t.classList.toggle("stb-min",m);try{localStorage.setItem(k,m?"min":"")}catch(e){}};
        try{if(localStorage.getItem(k)==="min")t.classList.add("stb-min")}catch(e){}
        t.querySelector(".stb-hide").addEventListener("click",()=>fold(true));
        t.querySelector(".stb-fab").addEventListener("click",()=>fold(false));
        t.querySelectorAll(".stb-item").forEach(i=>i.addEventListener("keydown",e=>{if(e.key==="Escape")document.activeElement.blur()}))})()
        JS
    end
  end
end
