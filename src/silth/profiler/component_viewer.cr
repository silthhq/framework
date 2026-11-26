module Silth
  module Profiler
    # The Components section: the scenarios of every `Silth::ComponentPreview`.
    #
    # ```text
    # /_silth/profiler/components                                  list
    # /_silth/profiler/components/<Preview>/<scenario>             one scenario (?w=375, ?p[name]=value)
    # /_silth/profiler/components/<Preview>/<scenario>/frame       the scenario alone, with the app's assets
    # ```
    module ComponentViewer
      PREFIX = "#{Middleware::PREFIX}/components"
      WIDTHS = {"" => "Full", "1024" => "1024", "768" => "768", "375" => "375"}

      def self.index : String
        previews = ComponentPreview.all
        return %(<div class="s-card s-empty">No component preview yet. Add a <code>Silth::ComponentPreview</code> subclass in <code>src/components/previews</code>, or run <code>silth g component Name</code>.</div>) if previews.empty?
        previews.map do |(name, scenarios)|
          links = scenarios.map { |s| %(<a class="s-badge" href="#{PREFIX}/#{name}/#{s}">#{HTML.escape(s)}</a>) }.join(" ")
          description = ComponentPreview.description_of(name)
          %(<div class="s-card"><h3 class="mono">#{HTML.escape(name.rchop("Preview"))}</h3>#{description.empty? ? "" : %(<p class="s-muted" style="margin:-4px 0 10px">#{HTML.escape(description)}</p>)}<p style="display:flex;gap:6px;flex-wrap:wrap;margin:0">#{links.empty? ? %(<span class="s-muted">No scenario: add a public method returning a component.</span>) : links}</p></div>)
        end.join
      end

      # `components/<Preview>/<scenario>/frame` is served as is, outside the layout.
      def self.raw?(rest : String) : Bool
        rest.starts_with?("components/") && rest.ends_with?("/frame")
      end

      def self.serve_frame(ctx : Context, rest : String) : Nil
        _, preview, scenario = rest.rchop("/frame").split('/', 3) + ["", ""]
        component = build(preview, scenario, ctx.request.query_params) || raise NotFound.new("No such component preview")
        ctx.html(frame(component, ctx.csp_nonce))
      end

      # The page of one scenario: the frame, the props (editable), slots, usage.
      def self.show(rest : String, query : URI::Params, nonce : String?) : Dashboard::Page
        _, preview, scenario = rest.split('/', 3) + ["", ""]
        component = build(preview, scenario, query) || raise NotFound.new("No such component preview")
        base = "#{PREFIX}/#{preview}/#{scenario}"
        width = query["w"]?.try { |w| WIDTHS.has_key?(w) ? w : nil } || ""
        overrides = overrides(query)
        props_query = overrides.map { |k, v| "p[#{URI.encode_www_form(k)}]=#{URI.encode_www_form(v)}" }.join('&')
        frame_src = "#{base}/frame#{props_query.empty? ? "" : "?#{props_query}"}"
        others = (ComponentPreview.all.find { |(name, _)| name == preview }.try(&.[1]) || [] of String).map do |s|
          %(<a href="#{PREFIX}/#{preview}/#{s}" class="#{s == scenario ? "active" : ""}">#{HTML.escape(s)}</a>)
        end.join
        widths = WIDTHS.map do |w, label|
          query_string = [w.empty? ? nil : "w=#{w}", props_query.presence].compact.join('&')
          %(<a class="s-badge#{w == width ? " info" : ""}" href="#{base}#{query_string.empty? ? "" : "?#{query_string}"}">#{label}</a>)
        end.join(" ")
        description = ComponentPreview.description_of(preview)
        content = <<-HTML
          #{description.empty? ? "" : %(<p class="s-sub">#{HTML.escape(description)}</p>)}
          <nav class="s-tabs">#{others}</nav>
          <div class="s-preview-bar"><span class="s-muted">Width</span> #{widths}</div>
          <div class="s-preview-stage"><iframe class="s-preview-frame" src="#{HTML.escape(frame_src)}" title="#{HTML.escape(component.class.name)} preview" style="#{width.empty? ? "" : "width:#{width}px"}"></iframe></div>
          #{props_card(component, base, width)}
          #{slots_card(component)}
          <div class="s-card"><h3>Usage</h3><pre class="s-sql" style="margin:0">#{HTML.escape(usage(component))}</pre></div>
          <div class="s-card"><details class="s-more"><summary>Rendered HTML</summary><pre class="mono" style="white-space:pre-wrap;margin:0">#{HTML.escape(component.is_a?(LiveComponent) ? component.render_live : component.render)}</pre></details></div>
          <script#{nonce ? %( nonce="#{nonce}") : ""}>
            document.querySelectorAll(".s-preview-frame").forEach(f => f.addEventListener("load", () => {
              try { f.style.height = Math.max(160, f.contentDocument.documentElement.scrollHeight + 2) + "px" } catch (e) {}
            }))
          </script>
          HTML
        heading = %(<span class="mono">#{HTML.escape(component.class.name)}</span> <span class="s-muted">· #{HTML.escape(scenario)}</span>)
        actions = %(<a class="s-btn" href="#{HTML.escape(frame_src)}" target="_blank" rel="noopener">Open alone</a>)
        Dashboard::Page.new("#{component.class.name} · #{scenario}", content, heading: heading,
          crumb: %(<span class="s-crumb"><a href="#{PREFIX}">Components</a> /</span>), actions: actions)
      end

      # A standalone page with the app's stylesheet, import map and the Silth
      # runtime (live components work, and live reload in development).
      def self.frame(component : Component, nonce : String?) : String
        nonce_attr = nonce ? %( nonce="#{nonce}") : ""
        stylesheets = Silth.config.has?("previews.stylesheets") ? Silth.config.array("previews.stylesheets") : default_stylesheets
        html = component.is_a?(LiveComponent) ? component.render_live : component.render
        String.build do |io|
          io << %(<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">)
          io << "<title>" << HTML.escape(component.class.name) << " preview</title>"
          stylesheets.each { |path| io << %(<link rel="stylesheet" href=") << HTML.escape(Silth.assets.path(path)) << %(">) }
          io << %(<style#{nonce_attr}>body.silth-preview{padding:24px;min-height:0}.silth-sr-only{position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%);white-space:nowrap}</style>)
          io << Silth.assets.importmap_tags("app", nonce)
          io << %(<script type="module" src="/_silth/silth.js"#{nonce_attr}></script>)
          if Silth.development? && Silth.config.bool("app.live_reload", true)
            io << %(<script type="module" src="/_silth/livereload.js"#{nonce_attr}></script>)
          end
          io << %(</head><body class="silth-preview"><main><h1 class="silth-sr-only">) << HTML.escape(component.class.name) << " preview</h1>"
          io << html << "</main></body></html>"
        end
      end

      # Every stylesheet at the root of the assets directory, app.css first
      # (`previews.stylesheets` in the config lists others).
      def self.default_stylesheets : Array(String)
        dir = Silth.assets.source_dir
        names = Dir.exists?(dir) ? Dir.children(dir).select(&.ends_with?(".css")).sort : [] of String
        names.sort_by { |n| n == "app.css" ? 0 : 1 }
      end

      private def self.build(preview : String, scenario : String, query : URI::Params) : Component?
        component = ComponentPreview.build(preview, scenario) || return nil
        overrides(query).each { |name, text| component.assign_prop_text(name, text) }
        component
      end

      # `p[name]=value` pairs (the last value wins: a checkbox follows its hidden field).
      private def self.overrides(query : URI::Params) : Hash(String, String)
        result = {} of String => String
        query.each { |key, _| key.match(/\Ap\[(\w+)\]\z/).try { |m| result[m[1]] = query.fetch_all(key).last } }
        result
      end

      private def self.props_card(component : Component, base : String, width : String) : String
        specs = component.prop_specs
        return %(<div class="s-card"><h3>Props</h3><p class="s-muted" style="margin:0">No prop.</p></div>) if specs.empty?
        rows = specs.map do |spec|
          input = if spec.editable
                    value = text_value(spec)
                    if spec.type == "Bool"
                      %(<input type="hidden" name="p[#{spec.name}]" value="false"><input type="checkbox" name="p[#{spec.name}]" value="true"#{spec.value == "true" ? " checked" : ""} aria-label="#{spec.name}">)
                    else
                      %(<input class="s-input" name="p[#{spec.name}]" value="#{HTML.escape(value)}" aria-label="#{spec.name}" style="width:100%">)
                    end
                  else
                    %(<code>#{HTML.escape(spec.value[0, 200])}</code>)
                  end
          flags = "#{spec.nilable ? " nilable" : ""}#{spec.writable ? " writable" : ""}"
          %(<tr><td class="mono">#{spec.name}</td><td class="mono s-muted">#{HTML.escape(spec.type)}#{flags.empty? ? "" : %(<span class="s-muted">,#{flags}</span>)}</td><td class="mono s-muted">#{HTML.escape(spec.default == "nil" && !spec.nilable ? "required" : spec.default)}</td><td>#{input}</td></tr>)
        end.join
        <<-HTML
          <form class="s-card" method="get" action="#{base}"><h3>Props</h3>
            #{width.empty? ? "" : %(<input type="hidden" name="w" value="#{width}">)}
            <table class="s-table"><thead><tr><th>Name</th><th>Type</th><th>Default</th><th>Value</th></tr></thead><tbody>#{rows}</tbody></table>
            <p style="display:flex;gap:8px;margin:12px 0 0"><button class="s-btn primary" type="submit">Apply</button><a class="s-btn" href="#{base}#{width.empty? ? "" : "?w=#{width}"}">Reset</a></p>
          </form>
          HTML
      end

      # The value of a scalar prop as a form field shows it (strings without quotes).
      private def self.text_value(spec : Component::PropSpec) : String
        return "" if spec.value == "nil"
        return spec.value unless spec.type == "String"
        String.from_json(spec.value)
      rescue JSON::ParseException
        spec.value
      end

      private def self.slots_card(component : Component) : String
        slots = component.filled_slots
        list = slots.empty? ? %(<span class="s-muted">None filled in this scenario.</span>) : slots.map { |s| %(<span class="s-badge">#{HTML.escape(s)}</span>) }.join(" ")
        %(<div class="s-card"><h3>Slots</h3><p style="margin:0;display:flex;gap:6px;flex-wrap:wrap">#{list}</p></div>)
      end

      # The template code rendering this scenario.
      def self.usage(component : Component) : String
        component.preview_usage.try { |custom| return custom }
        props = component.prop_specs.reject { |s| s.value == "nil" || s.value == s.default }.map { |s| "#{s.name}: #{s.value}" }
        call = (["component #{component.class.name}"] + props).join(", ")
        slots = component.filled_slots
        return "<%= #{call} %>" if slots.empty?
        named = slots.reject("content").map { |s| %(  <% c.slot :#{s} do %>…<% end %>) }
        (["<% #{call} do |c| %>"] + named + (slots.includes?("content") ? ["  …"] : [] of String) + ["<% end %>"]).join('\n')
      end
    end
  end
end
