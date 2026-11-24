# String inflections used across the framework (table names, generators, routes…).
#
# ```
# Silth::Inflector.pluralize("category")  # => "categories"
# Silth::Inflector.tableize("BlogPost")   # => "blog_posts"
# Silth::Inflector.classify("blog_posts") # => "BlogPost"
# ```
module Silth::Inflector
  extend self

  UNCOUNTABLE = Set{"equipment", "information", "rice", "money", "species", "series", "fish", "sheep", "jeans", "police", "news", "data", "metadata", "feedback", "staff"}

  IRREGULAR = {
    "person" => "people", "man" => "men", "woman" => "women", "child" => "children",
    "tooth" => "teeth", "foot" => "feet", "mouse" => "mice", "goose" => "geese",
    "ox" => "oxen", "leaf" => "leaves", "life" => "lives", "knife" => "knives",
    "wife" => "wives", "half" => "halves", "status" => "statuses", "quiz" => "quizzes",
  }

  PLURAL_RULES = [
    {/(quiz)$/i, "\\1zes"},
    {/^(ox)$/i, "\\1en"},
    {/([m|l])ouse$/i, "\\1ice"},
    {/(matr|vert|ind)(?:ix|ex)$/i, "\\1ices"},
    {/(x|ch|ss|sh)$/i, "\\1es"},
    {/([^aeiouy]|qu)y$/i, "\\1ies"},
    {/(hive)$/i, "\\1s"},
    {/(?:([^f])fe|([lr])f)$/i, "\\1\\2ves"},
    {/sis$/i, "ses"},
    {/([ti])um$/i, "\\1a"},
    {/(buffal|tomat|her)o$/i, "\\1oes"},
    {/(bu)s$/i, "\\1ses"},
    {/(alias|status)$/i, "\\1es"},
    {/(octop|vir)us$/i, "\\1i"},
    {/(ax|test)is$/i, "\\1es"},
    {/s$/i, "s"},
    {/$/, "s"},
  ]

  SINGULAR_RULES = [
    {/(database)s$/i, "\\1"},
    {/(quiz)zes$/i, "\\1"},
    {/(matr)ices$/i, "\\1ix"},
    {/(vert|ind)ices$/i, "\\1ex"},
    {/^(ox)en/i, "\\1"},
    {/(alias|status)(es)?$/i, "\\1"},
    {/(octop|vir)(us|i)$/i, "\\1us"},
    {/^(a)x[ie]s$/i, "\\1xis"},
    {/(cris|test)(is|es)$/i, "\\1is"},
    {/(shoe)s$/i, "\\1"},
    {/(o)es$/i, "\\1"},
    {/(bus)(es)?$/i, "\\1"},
    {/([m|l])ice$/i, "\\1ouse"},
    {/(x|ch|ss|sh)es$/i, "\\1"},
    {/(m)ovies$/i, "\\1ovie"},
    {/(s)eries$/i, "\\1eries"},
    {/([^aeiouy]|qu)ies$/i, "\\1y"},
    {/([lr])ves$/i, "\\1f"},
    {/(tive)s$/i, "\\1"},
    {/(hive)s$/i, "\\1"},
    {/([^f])ves$/i, "\\1fe"},
    {/(^analy)(sis|ses)$/i, "\\1sis"},
    {/((a)naly|(b)a|(d)iagno|(p)arenthe|(p)rogno|(s)ynop|(t)he)(sis|ses)$/i, "\\1sis"},
    {/([ti])a$/i, "\\1um"},
    {/(n)ews$/i, "\\1ews"},
    {/(ss)$/i, "\\1"},
    {/s$/i, ""},
  ]

  def pluralize(word : String) : String
    return word if word.empty?
    prefix, last = split_last(word)
    lower = last.downcase
    return word if UNCOUNTABLE.includes?(lower)
    if irr = IRREGULAR[lower]?
      return prefix + match_case(last, irr)
    end
    IRREGULAR.each_value { |plural| return word if lower == plural }
    PLURAL_RULES.each do |(rule, replacement)|
      return prefix + last.sub(rule, replacement) if last.matches?(rule)
    end
    word
  end

  def singularize(word : String) : String
    return word if word.empty?
    prefix, last = split_last(word)
    lower = last.downcase
    return word if UNCOUNTABLE.includes?(lower)
    IRREGULAR.each do |singular, plural|
      return prefix + match_case(last, singular) if lower == plural
    end
    SINGULAR_RULES.each do |(rule, replacement)|
      return prefix + last.sub(rule, replacement) if last.matches?(rule)
    end
    word
  end

  # "BlogPost" / "blog-post" / "Blog post" => "blog_post"
  def underscore(word : String) : String
    word
      .gsub("::", "/")
      .gsub(/([A-Z\d]+)([A-Z][a-z])/, "\\1_\\2")
      .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
      .gsub(/[\s\-]+/, "_")
      .downcase
  end

  # "blog_post" => "BlogPost", "admin/users" => "Admin::Users"
  def camelize(word : String, upper_first = true) : String
    result = word.split('/').map do |part|
      part.split(/[_\-\s]+/).map_with_index do |piece, i|
        (i == 0 && !upper_first) ? piece.downcase : piece.capitalize
      end.join
    end.join("::")
    result
  end

  def dasherize(word : String) : String
    underscore(word).tr("_", "-")
  end

  # "author_id" => "Author", "created_at" => "Created at"
  def humanize(word : String) : String
    underscore(word).sub(/_id$/, "").tr("_", " ").strip.capitalize
  end

  def titleize(word : String) : String
    humanize(word).split(' ').map(&.capitalize).join(' ')
  end

  # "BlogPost" => "blog_posts", "Admin::User" => "admin_users"
  def tableize(class_name : String) : String
    pluralize(underscore(class_name.split("::").last))
  end

  # "blog_posts" => "BlogPost"
  def classify(table : String) : String
    camelize(singularize(table.split('.').last))
  end

  # "User" => "user_id"
  def foreign_key(class_name : String) : String
    underscore(class_name.split("::").last) + "_id"
  end

  # URL friendly slug: "Hello, Wörld!" => "hello-world"
  def parameterize(text : String, separator = "-") : String
    normalized = text.unicode_normalize(:nfkd).gsub(/[\x{0300}-\x{036f}]/, "")
    normalized.downcase.gsub(/[^a-z0-9]+/, separator).strip(separator[0])
  end

  def ordinalize(number : Int) : String
    abs = number.abs % 100
    suffix = if 11 <= abs <= 13
               "th"
             else
               case number.abs % 10
               when 1 then "st"
               when 2 then "nd"
               when 3 then "rd"
               else        "th"
               end
             end
    "#{number}#{suffix}"
  end

  private def split_last(word : String) : {String, String}
    if idx = word.rindex('_')
      {word[0..idx], word[(idx + 1)..]}
    else
      {"", word}
    end
  end

  private def match_case(source : String, target : String) : String
    source[0].uppercase? ? target.capitalize : target
  end
end
