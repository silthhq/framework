module Silth
  # Previews of view and live components, shown in the profiler at
  # `/_silth/profiler/components`: every public method without arguments is a
  # scenario that returns the component to show, its props and slots set.
  #
  # ```
  # # src/components/previews/alert_component_preview.cr
  # class AlertComponentPreview < Silth::ComponentPreview
  #   description "Inline messages, in four variants."
  #
  #   def info : Silth::Component
  #     AlertComponent.new(message: "Saved.", variant: "info")
  #   end
  #
  #   def danger : Silth::Component
  #     AlertComponent.new(message: "Something went wrong.", variant: "danger")
  #   end
  # end
  #
  # class CardComponentPreview < Silth::ComponentPreview
  #   def with_footer : Silth::Component
  #     CardComponent.new(title: "Stats").with_slots(content: "<p>42 visits</p>", footer: %(<a href="/stats">All stats</a>))
  #   end
  # end
  # ```
  #
  # The page renders the scenario in a frame with the app's stylesheet, at
  # several widths, lists its props (scalar ones can be edited on the page) and
  # slots, and gives the template code that renders it. The previews are the
  # catalogue of the app's UI kit.
  abstract class ComponentPreview
    # One line shown under the preview's name.
    macro description(text)
      def self.description : String
        {{text}}
      end
    end

    def self.description : String
      ""
    end

    # `{preview class, scenarios}` for every preview compiled in, sorted by name.
    def self.all : Array({String, Array(String)})
      list = [] of {String, Array(String)}
      {% for t in @type.all_subclasses.reject(&.abstract?) %}
        list << { {{t.name.stringify}}, [
          {% for m in t.methods.select { |m| m.visibility == :public && m.args.empty? && !m.name.ends_with?("=") && !m.name.ends_with?("?") } %}
            {{m.name.stringify}},
          {% end %}
        ] of String }
      {% end %}
      list.sort_by(&.[0])
    end

    # The description of the preview class *name*.
    def self.description_of(name : String) : String
      {% begin %}
        case name
        {% for t in @type.all_subclasses.reject(&.abstract?) %}
          when {{t.name.stringify}} then return {{t}}.description
        {% end %}
        end
      {% end %}
      ""
    end

    # The component scenario *scenario* of *preview* returns, nil when unknown.
    def self.build(preview : String, scenario : String) : Component?
      {% begin %}
        case {preview, scenario}
        {% for t in @type.all_subclasses.reject(&.abstract?) %}
          {% for m in t.methods.select { |m| m.visibility == :public && m.args.empty? && !m.name.ends_with?("=") && !m.name.ends_with?("?") } %}
            when { {{t.name.stringify}}, {{m.name.stringify}} }
              return {{t}}.new.{{m.name}}.as(Component)
          {% end %}
        {% end %}
        end
      {% end %}
      nil
    end

    def self.count : Int32
      all.sum { |(_, scenarios)| scenarios.size }
    end
  end
end
