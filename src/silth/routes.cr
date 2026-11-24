module Silth
  # Route definitions DSL. Use it through `Silth.routes`:
  #
  # ```
  # Silth.routes do
  #   get "/", HomeController, :index, name: "home"
  #   resources "posts", PostsController do
  #     resources "comments", CommentsController, only: [:create, :destroy]
  #   end
  #
  #   scope "/admin", name: "admin", middleware: [:auth, RequireAdmin] do
  #     get "/", Admin::DashboardController, :index
  #   end
  #
  #   api do # prefix /api, "api" middleware group (no session/CSRF)
  #     get "/status" { |ctx| ctx.json({ok: true}) }
  #   end
  # end
  # ```
  abstract class Routes
    record Frame, prefix : String, name : String, middleware : Array(Middleware), group : String?

    class_getter sets = [] of Routes

    def self.register(set : Routes) : Nil
      @@sets << set
    end

    getter! router : Router
    @frames = [Frame.new("", "", [] of Middleware, "web")]

    abstract def draw : Nil

    def draw_into(router : Router) : Nil
      @router = router
      draw
    end

    # :nodoc:
    def __add(method : String, path : String, endpoint : Endpoint, name : String? = nil,
              controller : String? = nil, action : String? = nil,
              middleware : Array(Middleware) = [] of Middleware,
              constraints : Hash(String, Regex) = {} of String => Regex,
              meta : Hash(String, String)? = nil) : Route
      frame = @frames.last
      full_path = join_path(frame.prefix, path)
      full_name = name ? frame.name + name : nil
      if full_name.nil? && controller && action
        auto = frame.name + Inflector.underscore(controller.split("::").last.sub(/Controller$/, "")) + "." + action
        full_name = auto unless router.has_route?(auto)
      end
      route = Route.new(method, full_path, endpoint, full_name, frame.group,
        frame.middleware + middleware, controller, action, constraints)
      meta.try &.each { |k, v| route.meta[k] = v }
      router.add(route)
    end

    # :nodoc:
    def __push(prefix : String, name : String?, middleware : Array(Middleware), group : String?) : Nil
      frame = @frames.last
      name_prefix = name ? frame.name + name.rchop('.') + "." : frame.name
      @frames << Frame.new(join_path(frame.prefix, prefix), name_prefix, frame.middleware + middleware, group || frame.group)
    end

    # :nodoc:
    def __pop : Nil
      @frames.pop if @frames.size > 1
    end

    # :nodoc:
    def __middleware(item : Middleware) : Middleware
      item
    end

    # :nodoc:
    def __middleware(item : Symbol | String) : Middleware
      Silth.app.middleware_alias(item.to_s)
    end

    private def join_path(prefix : String, path : String) : String
      joined = "/" + [prefix, path].map(&.strip('/')).reject(&.empty?).join('/')
      joined
    end

    # --- verbs -------------------------------------------------------------

    {% for verb in %w(get post put patch delete options any) %}
      macro {{verb.id}}(path, controller = nil, action = nil, name = nil, middleware = nil, constraints = nil, summary = nil, tags = nil, &block)
        \{% if block %}
          __add({{verb.upcase}}, \{{path}}, ->(\{{block.args.first || "_ctx".id}} : ::Silth::Context) { \{{block.body}}; nil },
            name: \{{name}},
            middleware: \{% if middleware %}[\{% for m in middleware %}__middleware(\{% if m.is_a?(Path) %}\{{m}}.new\{% else %}\{{m}}\{% end %}),\{% end %}] of ::Silth::Middleware\{% else %}[] of ::Silth::Middleware\{% end %},
            constraints: \{% if constraints %}\{{constraints}}.to_h.transform_keys(&.to_s)\{% else %}{} of String => Regex\{% end %},
            meta: {"summary" => \{{summary || ""}}, "tags" => \{{tags ? tags.join(",") : ""}}})
        \{% else %}
          __add({{verb.upcase}}, \{{path}},
            ->(__silth_ctx : ::Silth::Context) { \{{controller}}.new(__silth_ctx).__run_action(\{{action.id.stringify}}) { |__silth_c| __silth_c.\{{action.id}} }; nil },
            name: \{{name}}, controller: \{{controller.stringify}}, action: \{{action.id.stringify}},
            middleware: \{% if middleware %}[\{% for m in middleware %}__middleware(\{% if m.is_a?(Path) %}\{{m}}.new\{% else %}\{{m}}\{% end %}),\{% end %}] of ::Silth::Middleware\{% else %}[] of ::Silth::Middleware\{% end %},
            constraints: \{% if constraints %}\{{constraints}}.to_h.transform_keys(&.to_s)\{% else %}{} of String => Regex\{% end %},
            meta: {"summary" => \{{summary || ""}}, "tags" => \{{tags ? tags.join(",") : ""}}})
        \{% end %}
      end
    {% end %}

    # Groups routes under a path prefix, a name prefix, extra middleware and/or a middleware group.
    macro scope(prefix = "", name = nil, middleware = nil, group = nil, &block)
      __push({{prefix}}, {{name ? name.id.stringify : nil}},
        {% if middleware %}[{% for m in middleware %}__middleware({% if m.is_a?(Path) %}{{m}}.new{% else %}{{m}}{% end %}),{% end %}] of ::Silth::Middleware{% else %}[] of ::Silth::Middleware{% end %},
        {{group ? group.id.stringify : nil}})
      begin
        {{block.body}}
      ensure
        __pop
      end
    end

    # JSON API routes: `/api` prefix, `api.` names and the `api` middleware group.
    macro api(prefix = "/api", name = "api", middleware = nil, &block)
      scope({{prefix}}, name: {{name}}, group: "api"{% if middleware %}, middleware: {{middleware}}{% end %}) do
        {{block.body}}
      end
    end

    # RESTful routes: index new create show edit update destroy.
    # Only actions defined by the controller are registered.
    macro resources(name, controller, only = nil, except = nil, param = "id", middleware = nil, path = nil, &block)
      {% res = name.id.stringify %}
      {% base = path || "/" + res %}
      {% all = %w(index new create show edit update destroy) %}
      {% actions = only ? only.map(&.id.stringify) : all %}
      {% if except %}{% actions = actions.reject { |a| except.map(&.id.stringify).includes?(a) } %}{% end %}
      {% ctrl = controller.resolve %}
      scope("", name: {{res}}{% if middleware %}, middleware: {{middleware}}{% end %}) do
        {% if actions.includes?("index") && ctrl.has_method?("index") %} get {{base}}, {{controller}}, :index, name: "index" {% end %}
        {% if actions.includes?("new") && ctrl.has_method?("new") %} get {{base + "/new"}}, {{controller}}, :new, name: "new" {% end %}
        {% if actions.includes?("create") && ctrl.has_method?("create") %} post {{base}}, {{controller}}, :create, name: "create" {% end %}
        {% if actions.includes?("show") && ctrl.has_method?("show") %} get {{base + "/:" + param}}, {{controller}}, :show, name: "show" {% end %}
        {% if actions.includes?("edit") && ctrl.has_method?("edit") %} get {{base + "/:" + param + "/edit"}}, {{controller}}, :edit, name: "edit" {% end %}
        {% if actions.includes?("update") && ctrl.has_method?("update") %}
          patch {{base + "/:" + param}}, {{controller}}, :update, name: "update"
          put {{base + "/:" + param}}, {{controller}}, :update, name: "replace"
        {% end %}
        {% if actions.includes?("destroy") && ctrl.has_method?("destroy") %} delete {{base + "/:" + param}}, {{controller}}, :destroy, name: "destroy" {% end %}
      end
      {% if block %}
        scope({{base + "/:" + (res[0..-2] + "_id")}}, name: {{res}}) do
          {{block.body}}
        end
      {% end %}
    end

    # Permanent redirect route.
    def redirect(from : String, to : String, status : Int32 = 301) : Route
      __add("GET", from, ->(ctx : Context) { ctx.redirect(to, status); nil })
    end
  end

  macro routes(file = __FILE__, line = __LINE__, &block)
    class ::SilthRoutes_{{ file.gsub(/[^A-Za-z0-9]/, "_").id }}_{{line}} < ::Silth::Routes
      def draw : Nil
        {{block.body}}
      end
    end
    ::Silth::Routes.register(::SilthRoutes_{{ file.gsub(/[^A-Za-z0-9]/, "_").id }}_{{line}}.new)
  end
end
