module Silth
  # Documents an API action for the generated OpenAPI 3.1 specification.
  #
  # ```
  # @[Silth::API(summary: "Create a post", tags: ["Posts"], body: CreatePostRequest, response: Post, status: 201)]
  # def create
  #   …
  # end
  # ```
  annotation API
  end

  # Automatic API documentation: `/docs/api` (UI) and `/docs/api/openapi.json`.
  # Routes of the `api` group are documented automatically; `@[Silth::API]`
  # adds summaries, request bodies and response schemas generated from Crystal types.
  module OpenAPI
    record Operation, summary : String?, description : String?, tags : Array(String), status : Int32,
      body : JSON::Any?, response : JSON::Any?, query : JSON::Any?, deprecated : Bool

    @@schemas = {} of String => JSON::Any

    def self.schemas : Hash(String, JSON::Any)
      @@schemas
    end

    # JSON Schema of a Crystal type (models, form requests, JSON::Serializable types, primitives).
    def self.schema_for(type : T.class) : JSON::Any forall T
      {% begin %}
        {% t = T %}
        {% if t <= String %}
          JSON.parse(%({"type":"string"}))
        {% elsif t <= Bool %}
          JSON.parse(%({"type":"boolean"}))
        {% elsif t <= Int %}
          JSON.parse(%({"type":"integer","format":"{{t <= Int64 ? "int64".id : "int32".id}}"}))
        {% elsif t <= Float %}
          JSON.parse(%({"type":"number"}))
        {% elsif t <= Time %}
          JSON.parse(%({"type":"string","format":"date-time"}))
        {% elsif t <= JSON::Any %}
          JSON.parse(%({}))
        {% elsif t <= Nil %}
          JSON.parse(%({"type":"null"}))
        {% elsif t.union? %}
          %types = [{% for u in t.union_types %}schema_for({{u}}),{% end %}] of JSON::Any
          JSON::Any.new({"anyOf" => JSON::Any.new(%types)})
        {% elsif t < Array %}
          JSON::Any.new({"type" => JSON::Any.new("array"), "items" => schema_for({{t.type_vars[0]}})})
        {% elsif t < Hash %}
          JSON::Any.new({"type" => JSON::Any.new("object"), "additionalProperties" => schema_for({{t.type_vars[1]}})})
        {% elsif t < Enum %}
          JSON::Any.new({"type" => JSON::Any.new("string"), "enum" => JSON::Any.new([{% for c in t.constants %}JSON::Any.new({{c.stringify.underscore}}),{% end %}] of JSON::Any)})
        {% elsif t < ::Silth::DB::Page %}
          JSON::Any.new({"type" => JSON::Any.new("object"), "properties" => JSON::Any.new({
            "data" => JSON::Any.new({"type" => JSON::Any.new("array"), "items" => schema_for({{t.type_vars[0]}})}),
            "meta" => JSON.parse(%({"type":"object","properties":{"page":{"type":"integer"},"per_page":{"type":"integer"},"total":{"type":"integer"},"total_pages":{"type":"integer"}}})),
          })})
        {% else %}
          %name = {{t.name.split("::").last.stringify}}
          unless @@schemas.has_key?(%name)
            @@schemas[%name] = JSON::Any.new({} of String => JSON::Any)
            %props = {} of String => JSON::Any
            %required = [] of JSON::Any
            {% for ivar in t.instance_vars %}
              {% if t < ::Silth::Model %}
                {% if (a = ivar.annotation(::Silth::Model::Column)) && !a[:hidden] %}
                  %props[{{a[:name]}}] = schema_for({{a[:type]}})
                  {% unless a[:nilable] %} %required << JSON::Any.new({{a[:name]}}) {% end %}
                {% end %}
              {% elsif t < ::Silth::FormRequest %}
                {% if a = ivar.annotation(::Silth::FormRequest::Field) %}
                  %s = schema_for({{a[:type]}}).as_h.dup
                  {% if a[:min] != nil %} %s[{{a[:type].resolve <= String ? "minLength" : "minimum"}}] = JSON::Any.new({{a[:min]}}.to_i64) {% end %}
                  {% if a[:max] != nil %} %s[{{a[:type].resolve <= String ? "maxLength" : "maximum"}}] = JSON::Any.new({{a[:max]}}.to_i64) {% end %}
                  {% if a[:email] %} %s["format"] = JSON::Any.new("email") {% end %}
                  {% if a[:url] %} %s["format"] = JSON::Any.new("uri") {% end %}
                  %props[{{a[:key]}}] = JSON::Any.new(%s)
                  {% unless a[:nilable] %} %required << JSON::Any.new({{a[:key]}}) {% end %}
                {% end %}
              {% elsif !ivar.name.starts_with?("__") && (!ivar.annotation(::JSON::Field) || !ivar.annotation(::JSON::Field)[:ignore]) %}
                %props[{{ivar.name.stringify}}] = schema_for({{ivar.type}})
                {% unless ivar.type.nilable? %} %required << JSON::Any.new({{ivar.name.stringify}}) {% end %}
              {% end %}
            {% end %}
            @@schemas[%name] = JSON::Any.new({"type" => JSON::Any.new("object"), "properties" => JSON::Any.new(%props), "required" => JSON::Any.new(%required)})
          end
          JSON::Any.new({"$ref" => JSON::Any.new("#/components/schemas/#{%name}")})
        {% end %}
      {% end %}
    end

    # Operations documented with `@[Silth::API]`, keyed by `Controller#action`.
    def self.operations : Hash(String, Operation)
      ops = {} of String => Operation
      {% for controller in Silth::Controller.all_subclasses %}
        {% for m in controller.methods %}
          {% if ann = m.annotation(::Silth::API) %}
            ops[{{"#{controller.name}##{m.name}"}}] = Operation.new(
              {{ann[:summary]}}, {{ann[:description]}},
              {% if ann[:tags] %}{{ann[:tags]}}.map(&.to_s){% else %}[] of String{% end %},
              {{ann[:status] || 200}},
              {% if ann[:body] %}schema_for({{ann[:body]}}){% else %}nil{% end %},
              {% if ann[:response] %}schema_for({{ann[:response]}}){% else %}nil{% end %},
              {% if ann[:query] %}schema_for({{ann[:query]}}){% else %}nil{% end %},
              {{ann[:deprecated] || false}})
          {% end %}
        {% end %}
      {% end %}
      ops
    end

    def self.document(router : Router = Silth.router) : String
      ops = operations
      config = Silth.config
      paths = {} of String => Hash(String, JSON::Any)
      router.routes.each do |route|
        op = route.handler_name.includes?('#') ? ops[route.handler_name]? : nil
        next unless route.group == "api" || op
        next if route.method == "ANY"
        path = "/" + route.segments.map { |s| s.starts_with?(':') || s.starts_with?('*') ? "{#{s[1..].sub(/<.*>\z/, "")}}" : s }.join('/')
        tag = op.try(&.tags.first?) || route.meta["tags"]?.presence.try(&.split(',').first) || route.segments.reject { |s| s == "api" || s.starts_with?(':') || s.matches?(/^v\d+$/) }.first?.try(&.capitalize) || "Default"
        operation = {} of String => JSON::Any
        operation["operationId"] = JSON::Any.new(route.name || "#{route.method.downcase}_#{path.gsub(/[^a-z0-9]+/i, "_")}")
        summary = op.try(&.summary) || route.meta["summary"]?.presence || "#{route.method} #{path}"
        operation["summary"] = JSON::Any.new(summary)
        operation["description"] = JSON::Any.new(op.try(&.description).not_nil!) if op.try(&.description)
        operation["tags"] = JSON::Any.new([JSON::Any.new(tag)])
        operation["deprecated"] = JSON::Any.new(true) if op.try(&.deprecated)
        params = route.param_names.map do |name|
          int = route.constraints[name]?.try(&.source.includes?("\\d")) || name.ends_with?("id")
          JSON::Any.new({"name" => JSON::Any.new(name.sub(/<.*>\z/, "")), "in" => JSON::Any.new("path"), "required" => JSON::Any.new(true),
                         "schema" => JSON.parse(int ? %({"type":"integer"}) : %({"type":"string"}))})
        end
        if (q = op.try(&.query)) && (ref = q["$ref"]?.try(&.as_s?))
          if props = @@schemas[ref.split('/').last]?.try(&.["properties"]?.try(&.as_h?))
            props.each { |k, v| params << JSON::Any.new({"name" => JSON::Any.new(k), "in" => JSON::Any.new("query"), "schema" => v}) }
          end
        end
        operation["parameters"] = JSON::Any.new(params) unless params.empty?
        if body = op.try(&.body)
          operation["requestBody"] = JSON::Any.new({"required" => JSON::Any.new(true), "content" => JSON::Any.new({"application/json" => JSON::Any.new({"schema" => body})})})
        end
        responses = {} of String => JSON::Any
        status = (op.try(&.status) || (route.method == "POST" ? 201 : route.method == "DELETE" ? 204 : 200)).to_s
        success = {"description" => JSON::Any.new(HTTP::Status.new(status.to_i).description || "OK")} of String => JSON::Any
        if resp = op.try(&.response)
          success["content"] = JSON::Any.new({"application/json" => JSON::Any.new({"schema" => resp})})
        end
        responses[status] = JSON::Any.new(success)
        requires_auth = route.pipeline.any? { |m| m.is_a?(Auth::Authenticate) }
        responses["401"] = JSON.parse(%({"$ref":"#/components/responses/Unauthorized"})) if requires_auth
        responses["404"] = JSON.parse(%({"$ref":"#/components/responses/NotFound"})) unless route.param_names.empty?
        responses["422"] = JSON.parse(%({"$ref":"#/components/responses/ValidationError"})) if op.try(&.body)
        responses["429"] = JSON.parse(%({"$ref":"#/components/responses/TooManyRequests"}))
        operation["responses"] = JSON::Any.new(responses)
        operation["security"] = JSON.parse(%([{"bearerAuth":[]}])) if requires_auth
        (paths[path] ||= {} of String => JSON::Any)[route.method.downcase] = JSON::Any.new(operation)
      end
      problem = %({"description":"%s","content":{"application/problem+json":{"schema":{"$ref":"#/components/schemas/Problem"}}}})
      @@schemas["Problem"] = JSON.parse(%({"type":"object","properties":{"type":{"type":"string"},"title":{"type":"string"},"status":{"type":"integer"},"detail":{"type":"string"},"errors":{"type":"object","additionalProperties":{"type":"array","items":{"type":"string"}}}}}))
      {
        "openapi"    => "3.1.0",
        "info"       => {"title" => config.string("api_docs.title", config.string("app.name", "Silth") + " API"), "version" => config.string("api_docs.version", config.string("app.version", "1.0.0")), "description" => config.string("api_docs.description", "Generated by Silth.")},
        "servers"    => [{"url" => config.string("app.url", "http://localhost:3000")}],
        "paths"      => paths,
        "components" => {
          "schemas"         => @@schemas,
          "securitySchemes" => {"bearerAuth" => {"type" => "http", "scheme" => "bearer"}},
          "responses"       => {
            "Unauthorized"    => JSON.parse(problem % "Unauthenticated"),
            "NotFound"        => JSON.parse(problem % "Not found"),
            "ValidationError" => JSON.parse(problem % "Validation failed"),
            "TooManyRequests" => JSON.parse(problem % "Too many requests"),
          },
        },
      }.to_pretty_json
    end

    # Serves the spec and the explorer UI.
    class Middleware < Silth::Middleware
      def initialize(@path : String = "/docs/api")
      end

      def call(ctx : Context, chain : Chain) : Nil
        if ctx.get? && ctx.path == "#{@path}/openapi.json"
          ctx.response.headers["Access-Control-Allow-Origin"] = "*"
          ctx.json(OpenAPI.document)
        elsif ctx.get? && ctx.path == @path
          ctx.html(OpenAPI.ui("#{@path}/openapi.json", ctx.csp_nonce))
        else
          chain.next(ctx)
        end
      end
    end

    def self.ui(spec_url : String, nonce : String?) : String
      n = nonce ? %( nonce="#{nonce}") : ""
      Brand.page("API reference", <<-HTML, nonce)
        <nav class="s-nav"><span class="s-brand">#{Brand::LOGO_SVG} API reference</span><a href="#{spec_url}">openapi.json</a>
        <input class="s-input" id="filter" placeholder="Filter endpoints…" style="margin-left:auto;width:260px"></nav>
        <div class="s-wrap" id="app"><p class="s-muted">Loading…</p></div>
        <style#{n}>
          .op{border:1px solid var(--rim);border-radius:10px;margin:10px 0;background:var(--abyss)}
          .op>summary{display:flex;gap:12px;align-items:center;padding:12px 14px;cursor:pointer;list-style:none}
          .verb{font:700 11px var(--mono);padding:4px 8px;border-radius:6px;min-width:64px;text-align:center}
          .get{background:rgba(166,220,255,.12);color:var(--soul)}.post{background:rgba(130,220,174,.12);color:var(--moss)}
          .put,.patch{background:rgba(227,187,116,.12);color:var(--ember)}.delete{background:rgba(255,107,129,.12);color:var(--blight)}
          .op .body{padding:0 16px 16px;border-top:1px solid var(--rim)} pre.json{background:var(--void);padding:12px;border-radius:8px;overflow:auto;border:1px solid var(--rim)}
          .try textarea{width:100%;min-height:90px;background:var(--void);color:var(--pale);border:1px solid var(--rim);border-radius:8px;font:12px var(--mono);padding:8px}
          .try button{margin-top:8px;background:var(--soul);color:var(--void);border:0;border-radius:8px;padding:8px 14px;font-weight:600;cursor:pointer}
        </style>
        <script#{n} type="module">
          const spec = await (await fetch(#{spec_url.to_json})).json();
          const app = document.getElementById("app");
          const resolve = (s) => s && s.$ref ? spec.components.schemas[s.$ref.split("/").pop()] : s;
          const example = (s, depth = 0) => { s = resolve(s) || {}; if (depth > 4) return null;
            if (s.anyOf) return example(s.anyOf.find(x => x.type !== "null") || s.anyOf[0], depth + 1);
            if (s.type === "object") { const o = {}; for (const [k, v] of Object.entries(s.properties || {})) o[k] = example(v, depth + 1); return o; }
            if (s.type === "array") return [example(s.items, depth + 1)];
            return { string: s.format === "date-time" ? new Date().toISOString() : (s.format === "email" ? "ada@example.com" : "string"), integer: 1, number: 1.5, boolean: true }[s.type] ?? null; };
          const esc = (t) => String(t).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
          const groups = {};
          for (const [path, ops] of Object.entries(spec.paths)) for (const [verb, op] of Object.entries(ops)) (groups[op.tags?.[0] || "Default"] ||= []).push({ path, verb, op });
          app.innerHTML = `<h1 class="s-title">${esc(spec.info.title)} <span class="s-badge">${esc(spec.info.version)}</span></h1><p class="s-sub">${esc(spec.info.description || "")}</p>` +
            Object.entries(groups).map(([tag, list]) => `<h2>${esc(tag)}</h2>` + list.map(({ path, verb, op }) => {
              const body = op.requestBody?.content?.["application/json"]?.schema;
              const ok = Object.entries(op.responses || {}).find(([c]) => c.startsWith("2"));
              const resp = ok?.[1]?.content?.["application/json"]?.schema;
              return `<details class="op" data-search="${esc((verb + " " + path + " " + (op.summary || "")).toLowerCase())}"><summary><span class="verb ${verb}">${verb.toUpperCase()}</span><code>${esc(path)}</code><span class="s-muted">${esc(op.summary || "")}</span>${op.security ? '<span class="s-badge warn">auth</span>' : ""}</summary><div class="body">
                ${(op.parameters || []).length ? `<h4>Parameters</h4><table class="s-table">${op.parameters.map(p => `<tr><td><code>${esc(p.name)}</code></td><td class="s-muted">${p.in}</td><td>${esc(p.schema?.type || "")}</td></tr>`).join("")}</table>` : ""}
                ${body ? `<h4>Request body</h4><pre class="json">${esc(JSON.stringify(example(body), null, 2))}</pre>` : ""}
                ${resp ? `<h4>Response ${ok[0]}</h4><pre class="json">${esc(JSON.stringify(example(resp), null, 2))}</pre>` : ""}
                <div class="try"><h4>Try it</h4><input class="s-input" placeholder="Bearer token (optional)" data-token style="width:100%;margin-bottom:8px">
                ${(op.parameters || []).filter(p => p.in === "path").map(p => `<input class="s-input" data-param="${esc(p.name)}" placeholder="${esc(p.name)}" style="margin:0 6px 8px 0">`).join("")}
                ${body ? `<textarea data-body>${esc(JSON.stringify(example(body), null, 2))}</textarea>` : ""}
                <button data-send="${esc(verb)} ${esc(path)}">Send request</button><pre class="json" data-out hidden></pre></div></div></details>`;
            }).join("")).join("");
          app.addEventListener("click", async (e) => {
            const btn = e.target.closest("[data-send]"); if (!btn) return;
            const box = btn.closest(".try"); let [verb, path] = btn.dataset.send.split(" ");
            box.querySelectorAll("[data-param]").forEach(i => path = path.replace(`{${i.dataset.param}}`, encodeURIComponent(i.value)));
            const headers = { "Accept": "application/json", "Content-Type": "application/json" };
            const token = box.querySelector("[data-token]").value; if (token) headers.Authorization = `Bearer ${token}`;
            const res = await fetch(path, { method: verb.toUpperCase(), headers, body: box.querySelector("[data-body]")?.value });
            const out = box.querySelector("[data-out]"); out.hidden = false;
            const text = await res.text(); let pretty = text; try { pretty = JSON.stringify(JSON.parse(text), null, 2); } catch {}
            out.textContent = `HTTP ${res.status}\\n\\n${pretty}`;
          });
          document.getElementById("filter").addEventListener("input", (e) => {
            const q = e.target.value.toLowerCase(); document.querySelectorAll(".op").forEach(op => op.hidden = q && !op.dataset.search.includes(q));
          });
        </script>
        HTML
    end
  end
end
