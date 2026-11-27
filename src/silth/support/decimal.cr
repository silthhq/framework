require "big"
require "json"

module Silth
  # An exact decimal number that keeps its scale: `Decimal.new("12.50")` prints
  # `12.50`, not `12.5`. Use it for money, quantities and rates: PostgreSQL
  # `NUMERIC` and MySQL `DECIMAL` columns are read as `Decimal`, and it is
  # written to JSON as a string so no client parses it into a float.
  #
  # ```
  # price = Decimal.new("19.90")
  # total = price * 3                            # => 59.70 (the scales add up: 2 + 0)
  # vat = (total * Decimal.new("0.20")).round(2) # => 11.94 (half to even)
  # (total + vat).to_s                           # => "71.64"
  # Decimal.new("10") / Decimal.new("4")         # => 2.5
  # Decimal.new("1.005").round(2, :ties_away)    # => 1.01
  # Decimal.new("12.345").to_fixed(2)            # => "12.35", `truncate(2)` gives 12.34
  # {"total" => total}.to_json                   # => {"total":"59.70"}
  # ```
  #
  # Arithmetic is exact, except division: a quotient that does not terminate
  # stops at 28 decimal places (or 28-29 significant digits), rounded half to
  # even. Scales follow the usual decimal rules (`rust_decimal`, Java's
  # `BigDecimal`): the larger scale for `+` and `-`, the sum of the scales for
  # `*`; `round` never adds digits, `rescale` does.
  struct Decimal
    include Comparable(Decimal)
    include Comparable(Int)

    # Highest scale a division produces.
    MAX_DIVISION_SCALE = 28
    # Largest mantissa a non-terminating division produces (96 bits, like `rust_decimal`).
    MAX_DIVISION_MANTISSA = (BigInt.new(1) << 96) - 1

    class InvalidError < ArgumentError
      def initialize(text : String)
        super("Invalid decimal: #{text[0, 60].inspect}")
      end
    end

    # The unscaled integer: `12.50` is `1250` with a scale of 2.
    getter mantissa : BigInt
    # Digits after the decimal point.
    getter scale : Int32

    def initialize(@mantissa : BigInt, @scale : Int32 = 0)
      raise ArgumentError.new("Decimal scale cannot be negative (#{@scale})") if @scale < 0
    end

    def self.new(value : Int) : self
      new(value.to_big_i, 0)
    end

    def self.new(value : Decimal) : self
      value
    end

    # Parses `"12.50"`, `"-0.5"`, `".5"`, `"1e3"`, `"1.5E-3"` (surrounding spaces allowed).
    def self.new(text : String) : self
      parse?(text) || raise InvalidError.new(text)
    end

    # From a float, through its shortest representation: `0.1` gives `0.1`.
    def self.new(value : Float) : self
      raise InvalidError.new(value.to_s) unless value.finite?
      new(value.to_s)
    end

    def self.new(value : BigDecimal) : self
      new(value.value, value.scale.to_i32)
    end

    def self.zero : self
      new(BigInt.new(0), 0)
    end

    # :nodoc: used by `Enumerable#sum`.
    def self.additive_identity : self
      zero
    end

    # :nodoc: used by `Enumerable#product`.
    def self.multiplicative_identity : self
      new(1)
    end

    # Parses a decimal, or returns nil.
    def self.parse?(text : String) : Decimal?
      str = text.strip
      return nil if str.empty?
      if m = str.match(/\A([+-])?(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?\z/)
        int_part = m[2]
        frac = m[3]? || ""
        return nil if int_part.empty? && frac.empty?
        exponent = m[4]?.try(&.to_i?) || 0
        mantissa = BigInt.new((int_part + frac).lchop("0").presence || "0")
        scale = frac.size - exponent
        if scale < 0
          mantissa *= BigInt.new(10) ** (-scale)
          scale = 0
        end
        mantissa = -mantissa if m[1]? == "-"
        new(mantissa, scale)
      end
    end

    # --- arithmetic --------------------------------------------------------------

    def +(other : Decimal) : Decimal
      scale = Math.max(@scale, other.scale)
      Decimal.new(widen(scale) + other.widen(scale), scale)
    end

    def -(other : Decimal) : Decimal
      scale = Math.max(@scale, other.scale)
      Decimal.new(widen(scale) - other.widen(scale), scale)
    end

    def *(other : Decimal) : Decimal
      Decimal.new(@mantissa * other.mantissa, @scale + other.scale)
    end

    # Exact when the quotient terminates within 28 decimal places; rounded half to even otherwise.
    #
    # ```
    # Decimal.new("1.00") / 2 # => 0.50
    # Decimal.new("10") / 4   # => 2.5
    # Decimal.new("1") / 3    # => 0.3333333333333333333333333333
    # ```
    def /(other : Decimal) : Decimal
      raise DivisionByZeroError.new if other.zero?
      return Decimal.zero if zero?
      negative = (@mantissa < 0) != (other.mantissa < 0)
      numerator = @mantissa.abs
      denominator = other.mantissa.abs
      scale = @scale - other.scale
      if scale < 0
        numerator *= BigInt.new(10) ** (-scale)
        scale = 0
      end
      quotient, remainder = numerator.divmod(denominator)
      while !remainder.zero? && scale < MAX_DIVISION_SCALE && quotient * 10 + 9 <= MAX_DIVISION_MANTISSA
        digit, remainder = (remainder * 10).divmod(denominator)
        quotient = quotient * 10 + digit
        scale += 1
      end
      unless remainder.zero?
        digit, rest = (remainder * 10).divmod(denominator)
        quotient += 1 if digit > 5 || (digit == 5 && (!rest.zero? || quotient.odd?))
      end
      Decimal.new(negative ? -quotient : quotient, scale)
    end

    # The remainder of the division (same sign as `self`): `Decimal.new("7.5") % 2 # => 1.5`.
    def %(other : Decimal) : Decimal
      raise DivisionByZeroError.new if other.zero?
      scale = Math.max(@scale, other.scale)
      Decimal.new(widen(scale).remainder(other.widen(scale)), scale)
    end

    {% for op in %w(+ - * / %) %}
      def {{op.id}}(other : Int) : Decimal
        self {{op.id}} Decimal.new(other)
      end
    {% end %}

    def - : Decimal
      Decimal.new(-@mantissa, @scale)
    end

    def abs : Decimal
      negative? ? -self : self
    end

    def zero? : Bool
      @mantissa.zero?
    end

    def negative? : Bool
      @mantissa < 0
    end

    def positive? : Bool
      @mantissa > 0
    end

    # -1, 0 or 1.
    def sign : Int32
      @mantissa <=> 0
    end

    # Compares values, whatever the scales: `Decimal.new("1.50") == Decimal.new("1.5")`.
    def <=>(other : Decimal) : Int32
      scale = Math.max(@scale, other.scale)
      widen(scale) <=> other.widen(scale)
    end

    def <=>(other : Int) : Int32
      self <=> Decimal.new(other)
    end

    def hash(hasher)
      normalized = normalize
      hasher = normalized.mantissa.hash(hasher)
      normalized.scale.hash(hasher)
    end

    # --- rounding and scale ------------------------------------------------------

    # Rounds to *digits* decimal places (half to even by default, like banks and
    # `rust_decimal`'s `round_dp`). Never adds digits: `Decimal.new("1.5").round(2)` is `1.5`.
    #
    # Modes: `:ties_even`, `:ties_away` (half away from zero), `:to_zero`
    # (truncate), `:to_positive` (ceiling), `:to_negative` (floor).
    def round(digits : Int = 0, mode : Number::RoundingMode = :ties_even) : Decimal
      return self if digits >= @scale
      divisor = BigInt.new(10) ** (@scale - digits)
      quotient, remainder = @mantissa.abs.divmod(divisor)
      unless remainder.zero?
        up = case mode
             in .ties_even?   then remainder * 2 > divisor || (remainder * 2 == divisor && quotient.odd?)
             in .ties_away?   then remainder * 2 >= divisor
             in .to_zero?     then false
             in .to_positive? then !negative?
             in .to_negative? then negative?
             end
        quotient += 1 if up
      end
      Decimal.new(negative? ? -quotient : quotient, digits.to_i32)
    end

    # Drops the digits after *digits* decimal places: `Decimal.new("12.349").truncate(2) # => 12.34`.
    def truncate(digits : Int = 0) : Decimal
      round(digits, :to_zero)
    end

    def floor : Decimal
      round(0, :to_negative)
    end

    def ceil : Decimal
      round(0, :to_positive)
    end

    # Exactly *digits* decimal places: pads with zeros or rounds.
    #
    # ```
    # Decimal.new("12.5").rescale(2)   # => 12.50
    # Decimal.new("12.345").rescale(2) # => 12.34 (half to even)
    # ```
    def rescale(digits : Int, mode : Number::RoundingMode = :ties_even) : Decimal
      if digits >= @scale
        Decimal.new(@mantissa * BigInt.new(10) ** (digits - @scale), digits.to_i32)
      else
        round(digits, mode)
      end
    end

    # Without trailing zeros: `Decimal.new("12.500").normalize # => 12.5`.
    def normalize : Decimal
      return Decimal.zero if zero?
      mantissa = @mantissa
      scale = @scale
      while scale > 0 && (mantissa % 10).zero?
        mantissa //= 10
        scale -= 1
      end
      Decimal.new(mantissa, scale)
    end

    # The string with exactly *digits* decimal places: `Decimal.new("3").to_fixed(2) # => "3.00"`.
    def to_fixed(digits : Int, mode : Number::RoundingMode = :ties_even) : String
      rescale(digits, mode).to_s
    end

    # --- conversions -------------------------------------------------------------

    def to_s(io : IO) : Nil
      digits = @mantissa.abs.to_s
      io << '-' if negative?
      if @scale == 0
        io << digits
      else
        digits = digits.rjust(@scale + 1, '0')
        io << digits[0, digits.size - @scale] << '.' << digits[-@scale..]
      end
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end

    def to_f64 : Float64
      to_s.to_f64
    end

    def to_f : Float64
      to_f64
    end

    def to_f32 : Float32
      to_s.to_f32
    end

    # The integer part (truncated).
    def to_big_i : BigInt
      truncate(0).mantissa
    end

    def to_i64 : Int64
      to_big_i.to_i64
    end

    def to_i : Int32
      to_big_i.to_i32
    end

    def to_i32 : Int32
      to_i
    end

    def to_big_d : BigDecimal
      BigDecimal.new(@mantissa, @scale.to_u64)
    end

    # Written as a JSON string, scale kept: `"12.50"`.
    def to_json(json : JSON::Builder) : Nil
      json.string(to_s)
    end

    def to_json_object_key : String
      to_s
    end

    # Reads a JSON string (`"12.50"`) or number (`12.50`, kept exactly as written).
    def self.new(pull : JSON::PullParser) : self
      case pull.kind
      when .string?
        text = pull.read_string
        parse?(text) || raise JSON::ParseException.new("Invalid decimal #{text.inspect}", *pull.location)
      when .int?, .float?
        text = pull.raw_value
        pull.read_next
        new(text)
      else
        raise JSON::ParseException.new("Expected a decimal (string or number), got #{pull.kind}", *pull.location)
      end
    end

    def self.from_json_object_key?(key : String) : self?
      parse?(key)
    end

    # :nodoc: the mantissa at a larger *scale*.
    protected def widen(scale : Int32) : BigInt
      scale == @scale ? @mantissa : @mantissa * BigInt.new(10) ** (scale - @scale)
    end
  end
end

struct Int
  {% for op in %w(+ - * /) %}
    def {{op.id}}(other : Silth::Decimal) : Silth::Decimal
      Silth::Decimal.new(self) {{op.id}} other
    end
  {% end %}

  def <=>(other : Silth::Decimal) : Int32
    Silth::Decimal.new(self) <=> other
  end
end
