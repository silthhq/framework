module Silth
  # Internationalization with YAML catalogs in `config/locales/*.yml`.
  #
  # ```yaml
  # # config/locales/fr.yml
  # fr:
  #   posts:
  #     created: "Article « %{title} » créé"
  #     count:
  #       zero: "Aucun article"
  #       one: "Un article"
  #       other: "%{count} articles"
  # ```
  #
  # ```
  # I18n.t("posts.created", title: "Hello")    # current locale
  # I18n.t("posts.count", count: 3, locale: "fr")
  # I18n.l(Time.utc, "short")
  # ```
  module I18n
    @@translations = {} of String => Hash(String, String)
    @@default_locale = "en"
    @@available = [] of String
    @@fallbacks = {} of String => String
    @@missing_handler : Proc(String, String, Nil)?

    class_property default_locale : String
    class_getter available : Array(String)

    DEFAULTS = {
      "en" => {
        "date.formats.default"               => "%Y-%m-%d",
        "date.formats.short"                 => "%b %-d",
        "date.formats.long"                  => "%B %-d, %Y",
        "time.formats.default"               => "%a, %d %b %Y %H:%M",
        "time.formats.short"                 => "%d %b %H:%M",
        "time.formats.long"                  => "%B %-d, %Y %H:%M",
        "errors.messages.blank"              => "can't be blank",
        "errors.messages.too_short"          => "is too short (minimum is %{count} characters)",
        "errors.messages.too_long"           => "is too long (maximum is %{count} characters)",
        "errors.messages.invalid"            => "is invalid",
        "errors.messages.taken"              => "has already been taken",
        "errors.messages.inclusion"          => "is not included in the list",
        "errors.messages.exclusion"          => "is reserved",
        "errors.messages.not_a_number"       => "is not a number",
        "errors.messages.greater_than"       => "must be greater than %{count}",
        "errors.messages.less_than"          => "must be less than %{count}",
        "errors.messages.confirmation"       => "doesn't match confirmation",
        "errors.messages.email"              => "is not a valid email address",
        "errors.messages.accepted"           => "must be accepted",
        "errors.messages.url"                => "is not a valid URL",
      },
      "fr" => {
        "date.formats.default"               => "%d/%m/%Y",
        "date.formats.short"                 => "%-d %b",
        "date.formats.long"                  => "%-d %B %Y",
        "time.formats.default"               => "%d/%m/%Y %H:%M",
        "time.formats.short"                 => "%-d %b %H:%M",
        "time.formats.long"                  => "%-d %B %Y à %H:%M",
        "errors.messages.blank"              => "doit être rempli(e)",
        "errors.messages.too_short"          => "est trop court (au moins %{count} caractères)",
        "errors.messages.too_long"           => "est trop long (pas plus de %{count} caractères)",
        "errors.messages.invalid"            => "n'est pas valide",
        "errors.messages.taken"              => "n'est pas disponible",
        "errors.messages.inclusion"          => "n'est pas inclus(e) dans la liste",
        "errors.messages.exclusion"          => "n'est pas disponible",
        "errors.messages.not_a_number"       => "n'est pas un nombre",
        "errors.messages.greater_than"       => "doit être supérieur à %{count}",
        "errors.messages.less_than"          => "doit être inférieur à %{count}",
        "errors.messages.confirmation"       => "ne concorde pas avec la confirmation",
        "errors.messages.email"              => "n'est pas une adresse e-mail valide",
        "errors.messages.accepted"           => "doit être accepté(e)",
        "errors.messages.url"                => "n'est pas une URL valide",
      },
    }

    MONTHS = {
      "fr" => { %w(janvier février mars avril mai juin juillet août septembre octobre novembre décembre),
               %w(janv. févr. mars avr. mai juin juil. août sept. oct. nov. déc.),
               %w(dimanche lundi mardi mercredi jeudi vendredi samedi),
               %w(dim. lun. mar. mer. jeu. ven. sam.)},
    }

    def self.load(dir : String = "config/locales") : Nil
      @@translations.clear
      DEFAULTS.each { |locale, entries| @@translations[locale] = entries.dup }
      config = Silth.config
      @@default_locale = config.string("i18n.default_locale", "en")
      if Dir.exists?(dir)
        Dir.glob(File.join(dir, "**", "*.{yml,yaml}")).sort.each do |file|
          load_yaml(File.read(file), file)
        end
      end
      @@available = config.has?("i18n.available_locales") ? config.array("i18n.available_locales") : @@translations.keys
      @@fallbacks = config.hash("i18n.fallbacks")
    end

    def self.load_yaml(content : String, source = "<string>") : Nil
      YAML.parse(content).as_h.each do |locale, tree|
        target = (@@translations[locale.as_s] ||= {} of String => String)
        flatten(tree, "", target)
      end
    rescue ex
      raise ConfigError.new("Invalid locale file #{source}: #{ex.message}")
    end

    def self.store(locale : String, key : String, value : String) : Nil
      (@@translations[locale] ||= {} of String => String)[key] = value
    end

    private def self.flatten(node : YAML::Any, prefix : String, target : Hash(String, String)) : Nil
      if h = node.as_h?
        h.each { |k, v| flatten(v, prefix.empty? ? k.as_s : "#{prefix}.#{k.as_s}", target) }
      else
        target[prefix] = node.raw.to_s
      end
    end

    def self.on_missing(&block : String, String -> Nil) : Nil
      @@missing_handler = block
    end

    def self.current_locale : String
      Context.current?.try(&.locale) || @@default_locale
    end

    def self.t(key : String, locale : String? = nil, count : Int? = nil, default : String? = nil, **vars) : String
      loc = locale || current_locale
      value = lookup(loc, key, count)
      if value.nil?
        @@missing_handler.try &.call(loc, key)
        value = default || key
      end
      interpolate(value, count, vars)
    end

    def self.exists?(key : String, locale : String? = nil) : Bool
      !lookup(locale || current_locale, key, nil).nil?
    end

    private def self.lookup(locale : String, key : String, count : Int?) : String?
      chain = [locale]
      chain << locale.split('-').first if locale.includes?('-')
      if fb = @@fallbacks[locale]?
        chain << fb
      end
      chain << @@default_locale
      chain.uniq.each do |loc|
        table = @@translations[loc]? || next
        if count
          category = plural_category(loc, count)
          if v = table["#{key}.#{count == 0 ? "zero" : category}"]? || table["#{key}.#{category}"]? || table["#{key}.other"]?
            return v
          end
        end
        if v = table[key]?
          return v
        end
      end
      nil
    end

    # CLDR plural categories for common languages.
    def self.plural_category(locale : String, count : Int) : String
      n = count.abs
      case locale.split('-').first
      when "fr", "pt"
        n <= 1 ? "one" : "other"
      when "ja", "zh", "ko", "vi", "th", "id"
        "other"
      when "ru", "uk", "pl"
        mod10, mod100 = n % 10, n % 100
        if mod10 == 1 && mod100 != 11
          "one"
        elsif (2..4).includes?(mod10) && !(12..14).includes?(mod100)
          "few"
        else
          "many"
        end
      when "ar"
        n == 0 ? "zero" : n == 1 ? "one" : n == 2 ? "two" : (3..10).includes?(n % 100) ? "few" : (11..99).includes?(n % 100) ? "many" : "other"
      else
        n == 1 ? "one" : "other"
      end
    end

    private def self.interpolate(value : String, count : Int?, vars) : String
      return value unless value.includes?("%{")
      value.gsub(/%\{(\w+)\}/) do |match, m|
        name = m[1]
        if name == "count" && count
          count.to_s
        else
          found = nil
          vars.each { |k, v| found = v.to_s if k.to_s == name }
          found || match
        end
      end
    end

    # Localized date/time formatting.
    def self.l(time : Time, format : String = "default", locale : String? = nil) : String
      loc = locale || current_locale
      pattern = lookup(loc, "time.formats.#{format}", nil) || format
      if names = MONTHS[loc.split('-').first]?
        pattern = pattern
          .gsub("%B", names[0][time.month - 1])
          .gsub("%b", names[1][time.month - 1])
          .gsub("%A", names[2][time.day_of_week.value % 7])
          .gsub("%a", names[3][time.day_of_week.value % 7])
      end
      time.to_s(pattern)
    end

    # Picks the best locale from an `Accept-Language` header.
    def self.negotiate(header : String?) : String?
      return nil unless header
      candidates = header.split(',').map do |part|
        lang, _, q = part.strip.partition(";q=")
        {lang.strip, q.empty? ? 1.0 : (q.to_f? || 0.0)}
      end.sort_by { |(_, q)| -q }
      candidates.each do |(lang, _)|
        return lang if @@available.includes?(lang)
        base = lang.split('-').first
        return base if @@available.includes?(base)
      end
      nil
    end

    # Resolves the request locale: `?locale=`, then `locale` cookie, session, then Accept-Language.
    class LocaleMiddleware < Middleware
      def call(ctx : Context, chain : Chain) : Nil
        available = I18n.available
        locale = ctx.request.query_params["locale"]?.try { |l| l if available.includes?(l) }
        if locale
          ctx.set_cookie("locale", locale, max_age: 365.days)
        end
        if locale.nil? && (from_route = ctx.route_params["locale"]?.try { |l| l if available.includes?(l) })
          locale = from_route
          ctx.set_cookie("locale", from_route, max_age: 365.days) unless ctx.cookies["locale"]?.try(&.value) == from_route
        end
        locale ||= ctx.cookies["locale"]?.try(&.value).try { |l| l if available.includes?(l) }
        locale ||= I18n.negotiate(ctx.header("Accept-Language"))
        ctx.locale = locale || I18n.default_locale
        ctx.response.headers["Content-Language"] = ctx.locale
        chain.next(ctx)
      end
    end
  end
end
