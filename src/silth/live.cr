module Silth
  # Stateful server-rendered components updated over WebSocket (or HTTP fallback),
  # inspired by Symfony UX Live Components and Phoenix LiveView.
  #
  # ```
  # class SearchComponent < Silth::LiveComponent
  #   prop query : String = "", writable: true    # bound with silth-model="query"
  #   prop page : Int32 = 1
  #   template "components/search"
  #
  #   def results : Array(Post)
  #     Post.search([:title, :body], query).paginate(page, 10).items
  #   end
  #
  #   action def next_page
  #     @page = page + 1
  #   end
  # end
  # ```
  #
  # ```erb
  # <div>
  #   <input silth-model.debounce.300ms="query" value="<%= query %>">
  #   <% results.each do |post| %><p><%= post.title %></p><% end %>
  #   <button silth-click="next_page">More</button>
  # </div>
  # ```
  #
  # Embed with `<%= live SearchComponent, query: "crystal" %>` or as a page: `live "/search", SearchComponent`.
  #
  # A live template can embed other live components. Each child keeps its own
  # state across the parent's re-renders, until the parent passes it new props:
  #
  # ```erb
  # <% todos.each do |todo| %>
  #   <%= live TodoItem, key: "todo-#{todo.id}", todo_id: todo.id %>
  # <% end %>
  # ```
  #
  # The child calls the parent's actions with `notify_parent("refresh")`.
  abstract class LiveComponent < Component
    @__live_id : String? = nil
    @__emits = [] of {String, String}
    @__parent_calls = [] of {String, String}
    @__redirect : String? = nil
    @__user : Auth::Authenticatable? = nil
    @__props_fingerprint : String? = nil
    @__child_seq = 0

    # Marks a method as callable from the browser: `action def increment … end`.
    macro action(definition)
      {{definition}}

      # :nodoc:
      def __action_{{definition.name}}(__args : Array(JSON::Any)) : Nil
        {{definition.name}}(
          {% for arg, i in definition.args %}
            {% if arg.restriction %}
              {{arg.restriction}}.from_json((__args[{{i}}]? || JSON::Any.new(nil)).to_json),
            {% else %}
              __args[{{i}}]? || JSON::Any.new(nil),
            {% end %}
          {% end %}
        )
      end
    end

    # Called once when the component is first rendered.
    def mount : Nil
    end

    # Called after a writable prop changed from the browser.
    def updated(prop : String) : Nil
    end

    # Topics that trigger a re-render when `Silth::Live.refresh(topic)` is called.
    def subscriptions : Array(String)
      [] of String
    end

    def user : Auth::Authenticatable?
      @__user || Context.current?.try(&.auth_user)
    end

    def user=(@__user : Auth::Authenticatable?)
    end

    # Dispatches a browser event (`silth:<name>` on window).
    def emit(event : String, payload = nil) : Nil
      @__emits << {event, payload.to_json}
    end

    def redirect_to(url : String) : Nil
      @__redirect = url
    end

    # Calls an action of the enclosing live component, in the browser, once this
    # response is applied: `notify_parent("item_removed", id)`.
    def notify_parent(action : String, *args) : Nil
      @__parent_calls << {action, args.to_a.to_json}
    end

    # Renders a nested live component. Its id derives from this component's id and
    # `key` (default: its position), so it survives this component's re-renders.
    def live(klass : T.class, key : String | Int32 | Nil = nil, **props) : SafeHTML forall T
      @__child_seq += 1
      child = klass.new(**props)
      child.live_id = "#{live_id}-#{key || "#{klass.name.split("::").last.underscore}-#{@__child_seq}"}"
      child.props_fingerprint = Crypto.sha256(props.to_s)[0, 16]
      child.mount
      SafeHTML.new(child.render_live)
    end

    def render(io : IO) : Nil
      @__child_seq = 0
      super
    end

    # :nodoc:
    def props_fingerprint=(@__props_fingerprint : String?)
    end

    # :nodoc:
    def __parent_calls : Array({String, String})
      @__parent_calls
    end

    def live_id : String
      @__live_id ||= "lc-#{Crypto.hex_token(6)}"
    end

    def live_id=(@__live_id : String?)
    end

    # :nodoc:
    def __emits : Array({String, String})
      @__emits
    end

    # :nodoc:
    def __redirect : String?
      @__redirect
    end

    # :nodoc:
    def __state_json : String
      JSON.build do |json|
        json.object do
          {% begin %}
            {% for ivar in @type.instance_vars %}
              {% if ivar.annotation(::Silth::Component::Prop) %}
                json.field {{ivar.name.stringify}} do
                  %v = @{{ivar.name}}
                  %v.nil? ? json.null : %v.to_json(json)
                end
              {% end %}
            {% end %}
          {% end %}
        end
      end
    end

    # :nodoc:
    def __hydrate(state : JSON::Any) : Nil
      {% begin %}
        {% for ivar in @type.instance_vars %}
          {% if ann = ivar.annotation(::Silth::Component::Prop) %}
            if %v = state[{{ivar.name.stringify}}]?
              @{{ivar.name}} = %v.raw.nil? ? nil : {{ann[:type]}}.from_json(%v.to_json)
            end
          {% end %}
        {% end %}
      {% end %}
    end

    # :nodoc: applies a browser update to a writable prop.
    def __update(name : String, value : JSON::Any) : Bool
      {% begin %}
        case name
        {% for ivar in @type.instance_vars %}
          {% if (ann = ivar.annotation(::Silth::Component::Prop)) && ann[:writable] %}
            when {{ivar.name.stringify}}
              raw = value.raw
              {% if ann[:type].resolve == String %}
                @{{ivar.name}} = raw.nil? ? nil : (value.as_s? || raw.to_s)
              {% elsif ann[:type].resolve <= Number %}
                @{{ivar.name}} = raw.nil? || raw.to_s.empty? ? nil : {{ann[:type]}}.new(raw.to_s.to_f64? || 0)
              {% elsif ann[:type].resolve == Bool %}
                @{{ivar.name}} = raw == true || raw.to_s.in?("true", "1", "on")
              {% else %}
                @{{ivar.name}} = raw.nil? ? nil : {{ann[:type]}}.from_json(value.to_json)
              {% end %}
              updated({{ivar.name.stringify}})
              return true
          {% end %}
        {% end %}
        end
      {% end %}
      false
    end

    # :nodoc:
    def __dispatch(action : String, args : Array(JSON::Any)) : Bool
      {% begin %}
        case action
        {% for m in @type.methods.select(&.name.starts_with?("__action_")) %}
          when {{m.name.stringify[9..-1]}}
            {{m.name.id}}(args)
            return true
        {% end %}
        end
      {% end %}
      false
    end

    def signed_state : String
      Silth.verifier("live").generate(__state_json)
    end

    # Renders the component wrapped with its live metadata.
    def render_live : String
      inner = render
      subs = subscriptions
      String.build do |io|
        io << %(<div id=") << live_id << %(" data-silth-live=") << self.class.name << %(" data-silth-state=") << HTML.escape(signed_state) << '"'
        io << %( data-silth-subscribe=") << HTML.escape(subs.join(',')) << '"' unless subs.empty?
        io << %( data-silth-props=") << @__props_fingerprint << '"' if @__props_fingerprint
        io << '>' << inner << "</div>"
      end
    end

    # Instantiates a live component from its class name.
    def self.build(name : String) : LiveComponent?
      {% begin %}
        case name
        {% for klass in @type.all_subclasses.reject(&.abstract?) %}
          when {{klass.name.stringify}} then return {{klass}}.new
        {% end %}
        end
      {% end %}
      nil
    end
  end

  # Full page wrapper used by the `live "/path", Component` route.
  class LivePage(C) < Controller
    def show
      component = C.new
      component.mount
      content = SafeHTML.new(component.render_live)
      ctx.html(render_to_string("layouts/application", layout: false, content: content))
    end
  end

  module View::Helpers
    # `<%= live CounterComponent, count: 3 %>`
    def live(klass : T.class, **props) : SafeHTML forall T
      component = klass.new(**props)
      component.mount
      SafeHTML.new(component.render_live)
    end
  end

  abstract class Routes
    # Mounts a live component as a full page rendered inside `layouts/application`.
    macro live(path, component, name = nil)
      get {{path}}, ::Silth::LivePage({{component}}), :show, name: {{name}}
    end
  end

  module Live
    Log = ::Log.for("silth.live")

    # Re-renders every connected component subscribed to `topic`.
    def self.refresh(topic : String) : Nil
      PubSub.publish("live:#{topic}", "refresh", "{}")
    end

    # Runs a component request and returns the JSON response.
    def self.process(message : JSON::Any, user : Auth::Authenticatable?) : String
      DB.reset_stickiness # each action reads from replicas until it writes
      name = message["c"].as_s
      component = LiveComponent.build(name) || raise BadRequest.new("Unknown live component #{name}")
      component.user = user
      component.live_id = message["id"]?.try(&.as_s?)
      state = Silth.verifier("live").verify?(message["s"].as_s) || raise Forbidden.new("Invalid component state")
      component.__hydrate(JSON.parse(state))
      message["m"]?.try &.as_h?.try &.each { |k, v| component.__update(k, v) }
      if action = message["a"]?.try(&.as_s?)
        args = message["args"]?.try(&.as_a?) || [] of JSON::Any
        raise BadRequest.new("Unknown action #{action} on #{name}") unless component.__dispatch(action, args)
      end
      response(component, message["ref"]?.try(&.as_s?))
    end

    def self.response(component : LiveComponent, ref : String?) : String
      JSON.build do |json|
        json.object do
          json.field "ref", ref if ref
          json.field "id", component.live_id
          if url = component.__redirect
            json.field "redirect", url
          else
            json.field "html", component.render
            json.field "s", component.signed_state
          end
          json.field "emits" do
            json.array do
              component.__emits.each do |(event, payload)|
                json.object do
                  json.field "event", event
                  json.field("payload") { json.raw(payload) }
                end
              end
            end
          end
          unless component.__parent_calls.empty?
            json.field "parent" do
              json.array do
                component.__parent_calls.each do |(action, args)|
                  json.object do
                    json.field "a", action
                    json.field("args") { json.raw(args) }
                  end
                end
              end
            end
          end
        end
      end
    end

    # Serves `/_silth/live` (WebSocket and HTTP POST fallback).
    class Endpoint < Silth::Middleware
      PATH = "/_silth/live"
      SOCKET = "/_silth/socket"

      def call(ctx : Context, chain : Chain) : Nil
        if ctx.path == SOCKET && Realtime.upgrade?(ctx)
          Realtime.serve_channels(ctx)
        elsif ctx.path == PATH && Realtime.upgrade?(ctx)
          serve_socket(ctx)
        elsif ctx.path == Upload::PATH
          verify_origin!(ctx)
          Upload.handle(ctx)
        elsif ctx.path == PATH && ctx.request.method == "POST"
          verify_origin!(ctx)
          body = ctx.request.body.try(&.gets_to_end) || "{}"
          ctx.json(Live.process(JSON.parse(body), Realtime.resolve_user(ctx)))
        else
          chain.next(ctx)
        end
      end

      private def verify_origin!(ctx : Context) : Nil
        site = ctx.header("Sec-Fetch-Site")
        return if site.nil? || site == "same-origin"
        raise Forbidden.new("Cross-site live component request")
      end

      private def serve_socket(ctx : Context) : Nil
        Realtime.accept(ctx) do |ws, user|
          mutex = Mutex.new
          mounted = {} of String => {String, String}
          subs = [] of {String, UInt64}
          send = ->(text : String) { mutex.synchronize { ws.send(text) rescue nil }; nil }
          ws.on_message do |raw|
            begin
              msg = JSON.parse(raw)
              if msg["type"]?.try(&.as_s?) == "mount"
                mount_id = msg["id"].as_s
                mounted[mount_id] = {msg["c"].as_s, msg["s"].as_s}
                (msg["topics"]?.try(&.as_a?) || [] of JSON::Any).each do |t|
                  topic = "live:#{t.as_s}"
                  sub = PubSub.subscribe(topic) do |_, _|
                    if entry = mounted[mount_id]?
                      refresh = JSON.parse({c: entry[0], s: entry[1], id: mount_id}.to_json)
                      result = Live.process(refresh, user)
                      mounted[mount_id] = {entry[0], JSON.parse(result)["s"]?.try(&.as_s) || entry[1]}
                      send.call(result)
                    end
                  end
                  subs << {topic, sub}
                end
              else
                result = Live.process(msg, user)
                if (comp_id = msg["id"]?.try(&.as_s?)) && (st = JSON.parse(result)["s"]?.try(&.as_s?))
                  mounted[comp_id] = {msg["c"].as_s, st}
                end
                send.call(result)
              end
            rescue ex
              Log.warn(exception: ex) { "Live component error" }
              send.call({ref: (JSON.parse(raw)["ref"]? rescue nil), error: Silth.development? ? ex.message : "Component error"}.to_json)
            end
          end
          ws.on_close { subs.each { |(t, s)| PubSub.unsubscribe(t, s) } }
        end
      end
    end
  end
end
