module Silth::ORM
  # Converts database values (and form strings) into Crystal column types.
  module Cast
    extend self

    alias Value = Silth::DB::Value

    def cast(v : Value, t : String.class) : String?
      case v
      when Nil    then nil
      when String then v
      when Bytes  then String.new(v)
      when Time   then v.to_rfc3339
      when JSON::Any then v.as_s? || v.to_json
      else             v.to_s
      end
    end

    {% for type, conv in {Int32 => "to_i32", Int64 => "to_i64", Int16 => "to_i16", Float64 => "to_f64", Float32 => "to_f32"} %}
      def cast(v : Value, t : {{type}}.class) : {{type}}?
        case v
        when Nil    then nil
        when Int32, Int64, Float32, Float64 then v.{{conv.id}}
        when Bool   then v ? {{type}}.new(1) : {{type}}.new(0)
        when String then v.strip.empty? ? nil : (v.strip.{{conv.id}}? || raise CastError.new(v, {{type.stringify}}))
        else             raise CastError.new(v.to_s, {{type.stringify}})
        end
      end
    {% end %}

    def cast(v : Value, t : Bool.class) : Bool?
      case v
      when Nil    then nil
      when Bool   then v
      when Int32, Int64 then v != 0
      when String then v.empty? ? nil : %w(1 t true on yes).includes?(v.downcase)
      else             raise CastError.new(v.to_s, "Bool")
      end
    end

    def cast(v : Value, t : Time.class) : Time?
      case v
      when Nil    then nil
      when Time   then v
      when String then v.strip.empty? ? nil : DB.parse_time(v)
      when Int32, Int64 then Time.unix(v.to_i64)
      else             raise CastError.new(v.to_s, "Time")
      end
    end

    def cast(v : Value, t : JSON::Any.class) : JSON::Any?
      case v
      when Nil       then nil
      when JSON::Any then v
      when String    then v.empty? ? nil : JSON.parse(v)
      when Bytes     then JSON::Any.new(Base64.strict_encode(v))
      when Time      then JSON::Any.new(v.to_rfc3339)
      else                JSON.parse(v.to_json)
      end
    end

    def cast(v : Value, t : Bytes.class) : Bytes?
      case v
      when Nil    then nil
      when Bytes  then v
      when String then v.to_slice
      else             raise CastError.new(v.to_s, "Bytes")
      end
    end

    def cast(v : Value, t : UUID.class) : UUID?
      case v
      when Nil    then nil
      when String then v.empty? ? nil : UUID.new(v)
      else             raise CastError.new(v.to_s, "UUID")
      end
    end

    {% for type, conv in {Float32 => "to_f32", Float64 => "to_f64", Int64 => "to_i64", Int32 => "to_i32"} %}
      def cast(v : Value, t : Array({{type}}).class) : Array({{type}})?
        case v
        when Nil then nil
        when Array({{type}}) then v
        when Array(Float32), Array(Float64), Array(Int32), Array(Int64) then v.map(&.{{conv.id}})
        when JSON::Any then v.as_a.map { |e| e.raw.as(Int64 | Float64).{{conv.id}} }
        when String
          text = v.strip
          return [] of {{type}} if text.empty? || text == "[]" || text == "{}"
          text.strip("[]{}").split(',').map(&.strip.{{conv.id}})
        else raise CastError.new(v.to_s, "Array({{type}})")
        end
      end
    {% end %}

    def cast(v : Value, t : Array(String).class) : Array(String)?
      case v
      when Nil           then nil
      when Array(String) then v
      when Array         then v.map(&.to_s)
      when JSON::Any     then v.as_a.map { |e| e.as_s? || e.to_json }
      when String
        text = v.strip
        if text.starts_with?('[')
          Array(String).from_json(text)
        elsif text.starts_with?('{')
          text.strip("{}").split(',').map(&.strip.strip('"')).reject(&.empty?)
        else
          text.split(',').map(&.strip).reject(&.empty?)
        end
      else raise CastError.new(v.to_s, "Array(String)")
      end
    end

    # Enums (stored as integers or names) and custom types implementing `.from_db`
    # or `JSON::Serializable` (typed JSON columns).
    def cast(v : Value, t : T.class) : T? forall T
      return nil if v.nil?
      {% if T < Enum %}
        case v
        when Int32, Int64 then T.from_value(v.to_i64)
        when String       then v.to_i64?.try { |i| T.from_value(i) } || T.parse(v)
        else                   raise CastError.new(v.to_s, {{T.stringify}})
        end
      {% elsif T.class.has_method?(:from_db) %}
        T.from_db(v)
      {% elsif T.class.has_method?(:from_json) %}
        case v
        when String    then T.from_json(v)
        when JSON::Any then T.from_json(v.to_json)
        else                raise CastError.new(v.to_s, {{T.stringify}})
        end
      {% else %}
        {% raise "Silth::ORM: no cast available for #{T}; define `self.from_db(value)`" %}
      {% end %}
    end

    # Crystal value → database value.
    def to_db(value) : Value
      case value
      when Nil, Bool, Int32, Int64, Float32, Float64, String, Bytes, Time, JSON::Any then value
      when Array(String), Array(Int32), Array(Int64), Array(Float32), Array(Float64) then value
      when Int8, Int16, UInt8, UInt16 then value.to_i32
      when UInt32, UInt64            then value.to_i64
      when Enum                      then value.value.to_i64
      when UUID                      then value.to_s
      else
        if value.responds_to?(:to_db)
          value.to_db
        else
          value.to_json
        end
      end
    end

    # JSON serialization that also handles `Bytes` (base64) and `Time` (RFC 3339).
    def write_json(json : JSON::Builder, value) : Nil
      case value
      when Nil   then json.null
      when Bytes then json.string(Base64.strict_encode(value))
      when Time  then json.string(value.to_rfc3339(fraction_digits: 3))
      else            value.to_json(json)
      end
    end

    class CastError < Silth::Error
      def initialize(value : String, type : String)
        super("Cannot cast #{value[0, 60].inspect} to #{type}")
      end
    end
  end
end
