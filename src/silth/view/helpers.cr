module Silth::View
  # HTML attribute rendering shared by helpers and form builders.
  module Attributes
    extend self

    def render(io : IO, attrs) : Nil
      attrs.each do |key, value|
        name = key.to_s
        name = name.tr("_", "-") if name.starts_with?("data_") || name.starts_with?("aria_") || name.starts_with?("hx_") || name.starts_with?("silth_")
        case value
        when Nil, false
          next
        when true
          io << ' ' << name
        when Hash, NamedTuple
          prefix = name
          value.each do |k, v|
            next if v.nil? || v == false
            io << ' ' << prefix << '-' << k.to_s.tr("_", "-")
            io << "=\"" << HTML.escape(v.to_s) << '"' unless v == true
          end
        else
          io << ' ' << name << "=\"" << HTML.escape(value.to_s) << '"'
        end
      end
    end

    def to_s(attrs) : String
      String.build { |io| render(io, attrs) }
    end
  end

  # Helpers available in every template (controllers, components, mails).
  module Helpers
    # --- escaping --------------------------------------------------------

    def raw(value) : SafeHTML
      SafeHTML.new(value.to_s)
    end

    def h(value) : String
      HTML.escape(value.to_s)
    end

    # --- tags --------------------------------------------------------------

    VOID_TAGS = Set{"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}

    def tag(name : String, content = nil, **attrs) : SafeHTML
      SafeHTML.new(String.build do |io|
        io << '<' << name
        Attributes.render(io, attrs)
        io << '>'
        unless VOID_TAGS.includes?(name)
          View.escape(io, content)
          io << "</" << name << '>'
        end
      end)
    end

    # Joins CSS classes conditionally: `class_names("btn", active: is_active, "btn-lg": big)`.
    def class_names(*names, **conditions) : String
      list = names.to_a.map(&.to_s).reject(&.empty?)
      conditions.each { |k, v| list << k.to_s if v }
      list.join(' ')
    end

    def link_to(text, url : String, **attrs) : SafeHTML
      tag("a", text, **attrs.merge(href: url))
    end

    # A tiny form submitting with any HTTP method (delete buttons…).
    def button_to(text, url : String, method : String = "post", confirm : String? = nil, **attrs) : SafeHTML
      SafeHTML.new(String.build do |io|
        io << %(<form method="post" action=") << HTML.escape(url) << '"'
        io << %( onsubmit="return confirm(') << HTML.escape(confirm.gsub("'", "\\'")) << %(')") if confirm
        io << %( class="button-to">)
        io << %(<input type="hidden" name="_method" value=") << method.downcase << %(">) unless method.downcase == "post"
        io << csrf_field.value
        io << "<button type=\"submit\""
        Attributes.render(io, attrs)
        io << '>'
        View.escape(io, text)
        io << "</button></form>"
      end)
    end

    def image_tag(src : String, alt : String = "", **attrs) : SafeHTML
      tag("img", nil, **attrs.merge(src: src.starts_with?("http") || src.starts_with?("/") ? src : asset_path(src), alt: alt))
    end

    # --- routing -----------------------------------------------------------

    def route(name : String | Symbol, **params) : String
      Silth.router.url_for(name.to_s, **params)
    end

    def current_path : String
      Context.current?.try(&.path) || "/"
    end

    def current_page?(path : String) : Bool
      current_path == path
    end

    def active_class(path : String, klass : String = "active", exact : Bool = false) : String?
      current = current_path
      match = exact ? current == path : (path == "/" ? current == "/" : current.starts_with?(path))
      match ? klass : nil
    end

    # --- assets ------------------------------------------------------------

    def asset_path(path : String) : String
      Silth.assets.path(path)
    end

    def stylesheet_tag(path : String, **attrs) : SafeHTML
      tag("link", nil, **attrs.merge(rel: "stylesheet", href: asset_path(path)))
    end

    def script_tag(path : String, type : String = "module", **attrs) : SafeHTML
      SafeHTML.new(%(<script type="#{type}" src="#{HTML.escape(asset_path(path))}"#{Attributes.to_s(attrs)}#{nonce_attr}></script>))
    end

    def importmap_tags(entry : String = "app") : SafeHTML
      SafeHTML.new(Silth.assets.importmap_tags(entry, csp_nonce))
    end

    # Silth client runtime (live components, channels, live reload in development).
    def silth_scripts : SafeHTML
      html = String.build do |io|
        io << %(<script type="module" src="/_silth/silth.js") << nonce_attr << "></script>"
        if Silth.env == "development" && Silth.config.bool("app.live_reload", true)
          io << %(<script type="module" src="/_silth/livereload.js") << nonce_attr << "></script>"
        end
      end
      SafeHTML.new(html)
    end

    # --- security ----------------------------------------------------------

    def csrf_token : String
      ctx = Context.current? || return ""
      CSRF.masked_token(ctx)
    end

    def csrf_field : SafeHTML
      SafeHTML.new(%(<input type="hidden" name="#{CSRF::FIELD}" value="#{csrf_token}" autocomplete="off">))
    end

    def csrf_meta_tags : SafeHTML
      SafeHTML.new(%(<meta name="csrf-param" content="#{CSRF::FIELD}"><meta name="csrf-token" content="#{csrf_token}">))
    end

    def csp_nonce : String?
      Context.current?.try(&.csp_nonce)
    end

    private def nonce_attr : String
      (n = csp_nonce) ? %( nonce="#{n}") : ""
    end

    # --- i18n --------------------------------------------------------------

    def t(key : String, count : Int? = nil, default : String? = nil, **vars) : String
      I18n.t(key, **vars.merge(locale: Context.current?.try(&.locale), count: count, default: default))
    end

    def l(time : Time, format : String = "default") : String
      I18n.l(time, format, locale: Context.current?.try(&.locale))
    end

    def current_locale : String
      Context.current?.try(&.locale) || I18n.default_locale
    end

    # --- text --------------------------------------------------------------

    def truncate(text : String?, length : Int32 = 100, omission : String = "…") : String
      return "" unless text
      text.size > length ? text[0, length - omission.size].rstrip + omission : text
    end

    def pluralize(count : Int, singular : String, plural : String? = nil) : String
      "#{count} #{count == 1 ? singular : (plural || Inflector.pluralize(singular))}"
    end

    def simple_format(text : String?) : SafeHTML
      return SafeHTML.empty unless text
      paragraphs = text.strip.split(/\n{2,}/).map { |p| "<p>#{HTML.escape(p).gsub("\n", "<br>")}</p>" }
      SafeHTML.new(paragraphs.join)
    end

    def markdown(text : String?) : SafeHTML
      SafeHTML.new(Markdown.to_html(text || ""))
    end

    def number_with_delimiter(number : Number, delimiter : String = ",", separator : String = ".") : String
      int, _, frac = number.to_s.partition('.')
      negative = int.starts_with?('-')
      int = int.lchop('-')
      grouped = int.reverse.scan(/\d{1,3}/).map(&.[0]).join(delimiter).reverse
      "#{negative ? "-" : ""}#{grouped}#{frac.empty? ? "" : separator + frac}"
    end

    def number_to_currency(amount : Number, unit : String = "$", precision : Int32 = 2, format : String = "%u%n") : String
      formatted = number_with_delimiter(amount.to_f.round(precision).format(decimal_places: precision, group: ""))
      format.sub("%u", unit).sub("%n", formatted)
    end

    def number_to_human_size(bytes : Int) : String
      units = %w(B KB MB GB TB PB)
      size = bytes.to_f
      i = 0
      while size >= 1024 && i < units.size - 1
        size /= 1024
        i += 1
      end
      i == 0 ? "#{bytes} B" : "#{size.round(1)} #{units[i]}"
    end

    def time_ago_in_words(time : Time, now : Time = Time.utc) : String
      seconds = (now - time).total_seconds.abs
      minutes = (seconds / 60).round.to_i
      words = case minutes
              when 0          then seconds < 30 ? I18n.t("time.less_than_a_minute", default: "less than a minute") : I18n.t("time.one_minute", default: "1 minute")
              when 1..44      then I18n.t("time.minutes", count: minutes, default: "#{minutes} minutes")
              when 45..89     then I18n.t("time.one_hour", default: "about 1 hour")
              when 90..1439   then I18n.t("time.hours", count: (minutes / 60).round.to_i, default: "about #{(minutes / 60).round.to_i} hours")
              when 1440..2519 then I18n.t("time.one_day", default: "1 day")
              when 2520..43199 then I18n.t("time.days", count: (minutes / 1440).round.to_i, default: "#{(minutes / 1440).round.to_i} days")
              when 43200..525599 then I18n.t("time.months", count: (minutes / 43200).round.to_i, default: "#{(minutes / 43200).round.to_i} months")
              else
                I18n.t("time.years", count: (minutes / 525600).round.to_i, default: "#{(minutes / 525600).round.to_i} years")
              end
      words
    end

    def time_tag(time : Time, format : String = "default") : SafeHTML
      tag("time", l(time, format), datetime: time.to_rfc3339)
    end

    def debug(value) : SafeHTML
      SafeHTML.new(%(<pre class="silth-debug">#{HTML.escape(value.pretty_inspect)}</pre>))
    end

    # --- flash & pagination -----------------------------------------------

    def flash_messages(klass : String = "flash") : SafeHTML
      ctx = Context.current? || return SafeHTML.empty
      flash = ctx.flash
      return SafeHTML.empty if flash.empty?
      SafeHTML.new(String.build do |io|
        flash.each do |kind, message|
          io << %(<div class=") << klass << ' ' << klass << '-' << HTML.escape(kind) << %(" role="status">) << HTML.escape(message) << "</div>"
        end
      end)
    end

    # Renders accessible pagination links for any `Silth::Pagination`.
    def paginate(page : Silth::DB::PageInfo, param : String = "page", window : Int32 = 2) : SafeHTML
      return SafeHTML.empty if page.total_pages <= 1
      ctx = Context.current?
      base = ctx.try(&.path) || "/"
      query = ctx.try(&.request.query_params.dup) || URI::Params.new
      link = ->(n : Int32) do
        query[param] = n.to_s
        "#{base}?#{query}"
      end
      SafeHTML.new(String.build do |io|
        io << %(<nav class="pagination" aria-label="Pagination">)
        if prev = page.prev_page
          io << %(<a rel="prev" href=") << HTML.escape(link.call(prev)) << %(">‹</a>)
        end
        pages = (1..page.total_pages).select { |n| n == 1 || n == page.total_pages || (n - page.page).abs <= window }
        last = 0
        pages.each do |n|
          io << %(<span class="gap">…</span>) if n - last > 1
          if n == page.page
            io << %(<span aria-current="page">) << n << "</span>"
          else
            io << %(<a href=") << HTML.escape(link.call(n)) << %(">) << n << "</a>"
          end
          last = n
        end
        if nxt = page.next_page
          io << %(<a rel="next" href=") << HTML.escape(link.call(nxt)) << %(">›</a>)
        end
        io << "</nav>"
      end)
    end

    # --- components --------------------------------------------------------

    def component(klass : T.class, **props) : SafeHTML forall T
      SafeHTML.new(String.build { |io| klass.new(**props).render(io) })
    end

    # Block form: `<% component CardComponent, title: "Hi" do %>…<% end %>`
    def component(klass : T.class, **props, &block : -> _) : Nil forall T
      instance = klass.new(**props)
      instance.slot = -> { block.call; nil }
      instance.render(@view_io)
    end

    # --- forms -------------------------------------------------------------

    # ```
    # <% form_with url: route("posts.create"), model: @post do |f| %>
    #   <%= f.label :title %>
    #   <%= f.text_field :title %>
    #   <%= f.errors_for :title %>
    #   <%= f.submit "Save" %>
    # <% end %>
    # ```
    def form_with(url : String, method : String = "post", model : Silth::Model? = nil, scope : String? = nil,
                  multipart : Bool = false, **attrs, & : FormBuilder ->) : Nil
      io = @view_io
      verb = method.downcase
      io << %(<form action=") << HTML.escape(url) << %(" method=") << (verb == "get" ? "get" : "post") << '"'
      io << %( enctype="multipart/form-data") if multipart
      Attributes.render(io, attrs)
      io << '>'
      unless verb == "get"
        io << %(<input type="hidden" name="_method" value=") << verb << %(">) unless verb == "post"
        io << csrf_field.value
      end
      scope ||= model.try { |m| Inflector.underscore(m.class.name.split("::").last) }
      yield FormBuilder.new(model, scope)
      io << "</form>"
    end
  end

  # Builds form fields bound to a model (values + validation errors) or plain params.
  class FormBuilder
    getter model : Silth::Model?
    getter scope : String?

    def initialize(@model : Silth::Model?, @scope : String?)
    end

    def field_name(field) : String
      (s = @scope) ? "#{s}[#{field}]" : field.to_s
    end

    def field_id(field) : String
      (s = @scope) ? "#{s}_#{field}" : field.to_s
    end

    def value_for(field) : String?
      if m = @model
        v = m.read_attribute(field.to_s)
        return v.is_a?(Time) ? v.to_s("%Y-%m-%dT%H:%M") : v.try(&.to_s)
      end
      Context.current?.try { |ctx| ctx.params[field_name(field)]? }
    end

    def errors(field) : Array(String)
      @model.try(&.errors[field.to_s]) || [] of String
    end

    def label(field, text : String? = nil, **attrs) : SafeHTML
      SafeHTML.new(%(<label for="#{field_id(field)}"#{View::Attributes.to_s(attrs)}>#{HTML.escape(text || Inflector.humanize(field.to_s))}</label>))
    end

    def input(field, type : String = "text", **attrs) : SafeHTML
      invalid = !errors(field).empty?
      value = type == "password" ? nil : value_for(field)
      SafeHTML.new(String.build do |io|
        io << %(<input type=") << type << %(" name=") << HTML.escape(field_name(field)) << %(" id=") << field_id(field) << '"'
        io << %( value=") << HTML.escape(value) << '"' if value && !attrs.has_key?(:value)
        io << %( aria-invalid="true" aria-describedby="#{field_id(field)}_error") if invalid
        View::Attributes.render(io, attrs)
        io << '>'
      end)
    end

    {% for kind in %w(text email password number date url tel search color range file) %}
      def {{kind.id}}_field(field, **attrs) : SafeHTML
        input(field, {{kind}}, **attrs)
      end
    {% end %}

    def datetime_field(field, **attrs) : SafeHTML
      input(field, "datetime-local", **attrs)
    end

    def hidden_field(field, **attrs) : SafeHTML
      input(field, "hidden", **attrs)
    end

    def text_area(field, rows : Int32 = 5, **attrs) : SafeHTML
      invalid = !errors(field).empty?
      SafeHTML.new(String.build do |io|
        io << %(<textarea name=") << HTML.escape(field_name(field)) << %(" id=") << field_id(field) << %(" rows=") << rows << '"'
        io << %( aria-invalid="true") if invalid
        View::Attributes.render(io, attrs)
        io << '>' << HTML.escape(value_for(field) || "") << "</textarea>"
      end)
    end

    def check_box(field, **attrs) : SafeHTML
      checked = %w(true 1 t on yes).includes?(value_for(field).to_s.downcase)
      SafeHTML.new(String.build do |io|
        io << %(<input type="hidden" name=") << HTML.escape(field_name(field)) << %(" value="0">)
        io << %(<input type="checkbox" value="1" name=") << HTML.escape(field_name(field)) << %(" id=") << field_id(field) << '"'
        io << " checked" if checked
        View::Attributes.render(io, attrs)
        io << '>'
      end)
    end

    # `options` as pairs `{label, value}` or plain strings.
    def select(field, options : Enumerable, include_blank : String? = nil, **attrs) : SafeHTML
      current = value_for(field)
      SafeHTML.new(String.build do |io|
        io << %(<select name=") << HTML.escape(field_name(field)) << %(" id=") << field_id(field) << '"'
        View::Attributes.render(io, attrs)
        io << '>'
        io << %(<option value="">) << HTML.escape(include_blank) << "</option>" if include_blank
        options.each do |opt|
          label, value = opt.is_a?(Tuple) ? {opt[0].to_s, opt[1].to_s} : {opt.to_s, opt.to_s}
          io << %(<option value=") << HTML.escape(value) << '"'
          io << " selected" if value == current
          io << '>' << HTML.escape(label) << "</option>"
        end
        io << "</select>"
      end)
    end

    def errors_for(field) : SafeHTML
      list = errors(field)
      return SafeHTML.empty if list.empty?
      SafeHTML.new(%(<p class="field-error" id="#{field_id(field)}_error">#{HTML.escape(list.join(", "))}</p>))
    end

    def submit(text : String = "Save", **attrs) : SafeHTML
      SafeHTML.new(%(<button type="submit"#{View::Attributes.to_s(attrs)}>#{HTML.escape(text)}</button>))
    end
  end
end
