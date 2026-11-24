require "html"

module Silth
  # A string that is already safe to output in HTML (never escaped again).
  struct SafeHTML
    getter value : String

    def initialize(@value : String = "")
    end

    def self.empty : SafeHTML
      new("")
    end

    def to_s(io : IO) : Nil
      io << @value
    end

    def +(other : SafeHTML) : SafeHTML
      SafeHTML.new(@value + other.value)
    end

    def +(other) : SafeHTML
      SafeHTML.new(@value + HTML.escape(other.to_s))
    end

    def empty? : Bool
      @value.empty?
    end

    def to_json(json : JSON::Builder) : Nil
      json.string(@value)
    end
  end

  module View
    # Used by compiled templates for `<%= %>` tags.
    def self.escape(io : IO, value : SafeHTML) : Nil
      io << value.value
    end

    def self.escape(io : IO, value : Nil) : Nil
    end

    def self.escape(io : IO, value) : Nil
      HTML.escape(value.to_s, io)
    end

    # Compile-time rendering of Silth templates (ECR syntax, auto-escaped).
    #
    # Templates live in `src/views` and are compiled into the binary:
    # `render "posts/index"` uses `src/views/posts/index.html.ecr`.
    module Rendering
      @view_io : IO = IO::Memory.new
      @__content_for : Hash(String, String)? = nil

      # Renders a template (optionally inside a layout) and returns the String.
      macro render_to_string(template, layout = false, **locals)
        {% path = template.ends_with?(".ecr") ? template : (template.includes?(".") ? "src/views/" + template + ".ecr" : "src/views/" + template + ".html.ecr") %}
        begin
          {% for key, value in locals %}
            %local{key} = {{value}}
          {% end %}
          {% for key, value in locals %}
            {{key.id}} = %local{key}
          {% end %}
          %prev = @view_io
          begin
            %content = String.build do |%io|
              @view_io = %io
              {{ run("./view/ecr_process", path, "@view_io") }}
            end
            {% if layout %}
              {% lpath = layout.ends_with?(".ecr") ? layout : "src/views/" + layout + ".html.ecr" %}
              String.build do |%io|
                @view_io = %io
                content = ::Silth::SafeHTML.new(%content)
                {{ run("./view/ecr_process", lpath, "@view_io") }}
              end
            {% else %}
              %content
            {% end %}
          ensure
            @view_io = %prev
          end
        end
      end

      # Renders a partial and returns it as `SafeHTML` for `<%= partial "posts/_card", post: post %>`.
      macro partial(template, **locals)
        ::Silth::SafeHTML.new(render_to_string({{template}}, layout: false{% unless locals.empty? %}, {{locals.double_splat}}{% end %}))
      end

      # Captures what the block writes into a `SafeHTML` value.
      def capture(&) : SafeHTML
        prev = @view_io
        rendered_out = String.build do |io|
          @view_io = io
          yield
        end
        SafeHTML.new(rendered_out)
      ensure
        @view_io = prev.not_nil!
      end

      def content_for(name : String | Symbol, &) : Nil
        (@__content_for ||= {} of String => String)[name.to_s] = capture { yield }.value
      end

      def content_for(name : String | Symbol, value : String) : Nil
        (@__content_for ||= {} of String => String)[name.to_s] = HTML.escape(value)
      end

      def content_for?(name : String | Symbol) : Bool
        !!@__content_for.try(&.has_key?(name.to_s))
      end

      def yield_content(name : String | Symbol, default : String = "") : SafeHTML
        SafeHTML.new(@__content_for.try(&.[name.to_s]?) || HTML.escape(default))
      end
    end
  end
end
