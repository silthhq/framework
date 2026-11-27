module Silth
  module Validation
    EMAIL = /\A[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+\z/
    URL   = /\Ahttps?:\/\/[^\s\/$.?#].[^\s]*\z/i

    # Validation errors keyed by attribute.
    class Errors
      include Enumerable({String, Array(String)})

      @messages = {} of String => Array(String)

      def add(field : String | Symbol, message : String) : Nil
        (@messages[field.to_s] ||= [] of String) << message
      end

      # Adds a translated message (`errors.messages.<key>`).
      def add_t(field : String | Symbol, key : String, count : Int? = nil) : Nil
        add(field, I18n.t("errors.messages.#{key}", count: count))
      end

      def [](field : String | Symbol) : Array(String)
        @messages[field.to_s]? || [] of String
      end

      def on?(field : String | Symbol) : Bool
        !self[field].empty?
      end

      def empty? : Bool
        @messages.empty?
      end

      def any? : Bool
        !empty?
      end

      def size : Int32
        @messages.values.sum(&.size)
      end

      def clear : Nil
        @messages.clear
      end

      def each(& : {String, Array(String)} ->)
        @messages.each { |k, v| yield({k, v}) }
      end

      def full_messages : Array(String)
        @messages.flat_map do |field, msgs|
          msgs.map { |m| field == "base" ? m : "#{Inflector.humanize(field)} #{m}" }
        end
      end

      def to_h : Hash(String, Array(String))
        @messages.dup
      end

      def to_json(json : JSON::Builder) : Nil
        @messages.to_json(json)
      end
    end

    def self.blank?(value) : Bool
      case value
      when Nil       then true
      when String    then value.strip.empty?
      when Array     then value.empty?
      when Hash      then value.empty?
      when JSON::Any then value.raw.nil? || (value.as_s? || "x").strip.empty?
      else                false
      end
    end

    def self.length_of(value) : Int32?
      case value
      when String then value.size
      when Array  then value.size
      else             nil
      end
    end

    def self.number(value) : Float64?
      case value
      when Int32, Int64, Float32, Float64, ::Silth::Decimal then value.to_f64
      when String                                           then value.to_f64?
      else                                                       nil
      end
    end
  end

  # Typed, validated request input (Laravel Form Requests).
  #
  # ```
  # class CreatePostRequest < Silth::FormRequest
  #   field title : String, min: 3, max: 120
  #   field body : String?
  #   field published : Bool = false
  #   field rating : Int32, min: 1, max: 5
  #   field email : String, email: true
  # end
  #
  # data = validate!(CreatePostRequest) # in a controller; 422 with errors when invalid
  # data.title
  # ```
  abstract class FormRequest
    annotation Field
    end

    getter errors = Validation::Errors.new

    macro field(decl, min = nil, max = nil, email = false, url = false, format = nil, in values = nil, key = nil, confirmed = false)
      {% type = decl.type.resolve %}
      {% nilable = type.nilable? %}
      {% base = type.union? ? type.union_types.reject(&.nilable?).first : type %}
      @[::Silth::FormRequest::Field(type: {{base}}, nilable: {{nilable}}, key: {{(key || decl.var.stringify)}}, min: {{min}}, max: {{max}}, email: {{email}}, url: {{url}}, format: {{format}}, values: {{values}}, confirmed: {{confirmed}})]
      @{{decl.var}} : {{base}}? = {% if decl.value.is_a?(Nop) %}nil{% else %}{{decl.value}}{% end %}

      def {{decl.var}} : {{nilable ? type : base}}
        {% if nilable %}@{{decl.var}}{% else %}@{{decl.var}}.not_nil!{% end %}
      end
    end

    def self.from_params!(params : Params) : self
      request = from_params(params)
      unless request.errors.empty?
        raise UnprocessableEntity.new("The given data was invalid", request.errors.to_h)
      end
      request
    end

    def self.from_params(params : Params) : self
      instance = new
      instance.__fill(params)
      instance.validate
      instance
    end

    # Override for cross-field validation; add to `errors`.
    def validate : Nil
    end

    def valid? : Bool
      @errors.empty?
    end

    # :nodoc:
    def __fill(params : Params) : Nil
      {% begin %}
        {% for ivar in @type.instance_vars %}
          {% if ann = ivar.annotation(::Silth::FormRequest::Field) %}
            %key = {{ann[:key]}}
            %raw = params[%key]?
            if %raw.nil? || %raw.strip.empty?
              {% if ann[:type].resolve == Bool %}
                @{{ivar.name}} = params.has?(%key) ? false : @{{ivar.name}}
              {% elsif !ann[:nilable] %}
                @errors.add_t(%key, "blank") if @{{ivar.name}}.nil?
              {% end %}
            else
              begin
                %value = ::Silth::ORM::Cast.cast(%raw.as(::Silth::DB::Value), {{ann[:type]}})
                @{{ivar.name}} = %value
                {% if ann[:min] != nil %}
                  if (%len = ::Silth::Validation.length_of(%value)) && %len < {{ann[:min]}}
                    @errors.add_t(%key, "too_short", {{ann[:min]}})
                  elsif (%num = (%value.is_a?(Number) ? %value.to_f64 : nil)) && %num < {{ann[:min]}}
                    @errors.add(%key, ::Silth::I18n.t("errors.messages.greater_than", count: {{ann[:min]}} - 1))
                  end
                {% end %}
                {% if ann[:max] != nil %}
                  if (%len = ::Silth::Validation.length_of(%value)) && %len > {{ann[:max]}}
                    @errors.add_t(%key, "too_long", {{ann[:max]}})
                  elsif (%num = (%value.is_a?(Number) ? %value.to_f64 : nil)) && %num > {{ann[:max]}}
                    @errors.add(%key, ::Silth::I18n.t("errors.messages.less_than", count: {{ann[:max]}} + 1))
                  end
                {% end %}
                {% if ann[:email] %}
                  @errors.add_t(%key, "email") unless %raw.matches?(::Silth::Validation::EMAIL)
                {% end %}
                {% if ann[:url] %}
                  @errors.add_t(%key, "url") unless %raw.matches?(::Silth::Validation::URL)
                {% end %}
                {% if ann[:format] %}
                  @errors.add_t(%key, "invalid") unless %raw.matches?({{ann[:format]}})
                {% end %}
                {% if ann[:values] %}
                  @errors.add_t(%key, "inclusion") unless {{ann[:values]}}.map(&.to_s).includes?(%raw)
                {% end %}
                {% if ann[:confirmed] %}
                  @errors.add_t(%key, "confirmation") unless params["#{%key}_confirmation"]? == %raw
                {% end %}
              rescue ::Silth::ORM::Cast::CastError
                @errors.add_t(%key, "invalid")
              end
            end
          {% end %}
        {% end %}
      {% end %}
    end
  end
end
