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

    def component_name : String
      self.class.name.split("::").last.sub(/Component$/, "")
    end
  end
end
