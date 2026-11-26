module Silth
  # Reusable, server rendered view components (inspired by Symfony UX TwigComponent).
  #
  # ```
  # class AlertComponent < Silth::Component
  #   prop message : String
  #   prop variant : String = "info"
  #   template "components/alert"   # src/views/components/alert.html.ecr
  # end
  # ```
  #
  # In templates:
  #
  # ```erb
  # <%= component AlertComponent, message: "Saved!", variant: "success" %>
  #
  # <% component CardComponent, title: "Stats" do %>
  #   <p>Inner content rendered where the card template calls <%%= yield_slot %>.</p>
  # <% end %>
  #
  # <% component CardComponent, title: "Stats" do |card| %>
  #   <% card.slot :footer do %><a href="/stats">All stats</a><% end %>
  #   <p>Default slot</p>
  # <% end %>
  # ```
  #
  # The card template places named slots with `<%%= yield_slot :footer %>` and tests
  # them with `slot?(:footer)`.
  abstract class Component
    include View::Rendering
    include View::Helpers

    annotation Prop
    end

    # A declared prop, as component previews show it.
    record PropSpec, name : String, type : String, nilable : Bool, writable : Bool, default : String, value : String, editable : Bool

    # Default slot as a block (set by the block form of `component`).
    property slot : (-> Nil)? = nil
    @__default_slot : String? = nil
    @__slots = {} of String => -> Nil

    def initialize(**props)
      assign_props(**props)
    end

    # :nodoc:
    def assign_props(**props : **T) : Nil forall T
      {% for key in T.keys %}
        self.{{key.id}} = props[{{key.symbolize}}]
      {% end %}
    end

    # Declares a property. Non nilable props without default are required.
    # `writable: true` lets live components accept updates from the browser (`silth-model`).
    macro prop(decl, writable = false)
      {% type = decl.type.resolve %}
      {% nilable = type.nilable? %}
      {% base = type.union? ? type.union_types.reject(&.nilable?).first : type %}
      @[::Silth::Component::Prop(type: {{base}}, nilable: {{nilable}}, writable: {{writable}})]
      @{{decl.var}} : {{base}}? {% if decl.value.is_a?(Nop) %} = nil {% else %} = {{decl.value}} {% end %}

      def {{decl.var}} : {{ nilable ? type : base }}
        {% if nilable %}
          @{{decl.var}}
        {% else %}
          %value = @{{decl.var}}
          raise ::Silth::Error.new("Missing prop '{{decl.var}}' for #{self.class.name}") if %value.nil?
          %value
        {% end %}
      end

      def {{decl.var}}=(value : {{base}}?)
        @{{decl.var}} = value
      end
    end

    # Declares the template used by `#render`.
    macro template(name)
      {% path = name.ends_with?(".ecr") ? name : "src/views/" + name + ".html.ecr" %}
      def render_template : Nil
        {{ run("./view/ecr_process", path, "@view_io") }}
      end
    end

    # Override to render without a template file.
    def render_template : Nil
      raise Error.new("#{self.class.name} has no template; use the `template` macro or override #render_template")
    end

    # Called right before rendering (compute derived state here).
    def before_render : Nil
    end

    def render(io : IO) : Nil
      prev = @view_io
      started = Time.instant
      @view_io = io
      before_render
      render_template
      Instrument.render("component #{self.class.name}", Time.instant - started)
    ensure
      @view_io = prev.not_nil!
    end

    def render : String
      String.build { |io| render(io) }
    end

    def to_s(io : IO) : Nil
      render(io)
    end

    # Outputs the block passed by the caller (default slot).
    def yield_slot : SafeHTML
      if html = @__default_slot
        @view_io << html
      else
        @slot.try &.call
      end
      SafeHTML.empty
    end

    # Outputs a named slot filled by the caller (nothing when it was not given).
    def yield_slot(name : Symbol | String) : SafeHTML
      @__slots[name.to_s]?.try &.call
      SafeHTML.empty
    end

    # Fills a named slot, from the caller's block: `<% card.slot :footer do %>…<% end %>`.
    def slot(name : Symbol | String, &block : -> _) : Nil
      @__slots[name.to_s] = -> { block.call; nil }
    end

    # True when the caller filled the named slot (or, without a name, the default one).
    def slot?(name : Symbol | String | Nil = nil) : Bool
      return @__slots.has_key?(name.to_s) if name
      !@__default_slot.to_s.strip.empty? || !@slot.nil?
    end

    # :nodoc: the default slot, rendered by the caller before the component.
    def default_slot_html=(@__default_slot : String?)
    end

    # Fills the slots with HTML, from code (previews, specs) rather than a
    # template block: *content* is the default slot.
    #
    # ```
    # CardComponent.new(title: "Stats").with_slots(content: "<p>42</p>", footer: %(<a href="/stats">All</a>))
    # ```
    def with_slots(content : String? = nil, **slots) : self
      @__default_slot = content if content
      slots.each { |name, html| fill_slot(name, html.to_s) }
      self
    end

    # Fills the named slot *name* with *html*.
    def fill_slot(name : Symbol | String, html : String) : Nil
      @__slots[name.to_s] = -> { @view_io << html; nil }
    end

    # Names of the slots the caller filled ("content" for the default one).
    def filled_slots : Array(String)
      names = @__slots.keys
      names.unshift("content") if slot?
      names
    end

    # The template code component previews show for this instance; nil gives the
    # generic one (props, then slots). Override it when the component is filled
    # through methods of its own (`tabs.tab …`, `menu.item …`).
    def preview_usage : String?
      nil
    end

    # The props this component declares, with their current values.
    def prop_specs : Array(PropSpec)
      specs = [] of PropSpec
      {% for ivar in @type.instance_vars %}
        {% ann = ivar.annotation(::Silth::Component::Prop) %}
        {% if ann %}
          {% type_name = ann[:type].resolve.name.stringify %}
          specs << PropSpec.new({{ivar.name.stringify}}, {{type_name}}, {{ann[:nilable]}}, {{ann[:writable]}},
            ({{ivar.default_value}}).inspect, @{{ivar.name}}.inspect, {{%w(String Int32 Int64 Float32 Float64 Bool).includes?(type_name)}})
        {% end %}
      {% end %}
      specs
    end

    # :nodoc: sets a scalar prop from a preview control (the text of a form field).
    def assign_prop_text(name : String, text : String) : Bool
      {% for ivar in @type.instance_vars %}
        {% ann = ivar.annotation(::Silth::Component::Prop) %}
        {% if ann %}
          {% type_name = ann[:type].resolve.name.stringify %}
          if name == {{ivar.name.stringify}}
            {% if ann[:nilable] %}
              if text.empty?
                @{{ivar.name}} = nil
                return true
              end
            {% end %}
            {% if type_name == "String" %}
              @{{ivar.name}} = text
              return true
            {% elsif type_name == "Bool" %}
              @{{ivar.name}} = text.in?("true", "1", "on", "yes")
              return true
            {% elsif type_name == "Int32" %}
              text.to_i32?.try { |v| @{{ivar.name}} = v; return true }
            {% elsif type_name == "Int64" %}
              text.to_i64?.try { |v| @{{ivar.name}} = v; return true }
            {% elsif type_name == "Float64" %}
              text.to_f64?.try { |v| @{{ivar.name}} = v; return true }
            {% elsif type_name == "Float32" %}
              text.to_f32?.try { |v| @{{ivar.name}} = v; return true }
            {% end %}
            return false
          end
        {% end %}
      {% end %}
      false
    end

    def component_name : String
      self.class.name.split("::").last.sub(/Component$/, "")
    end
  end
end
