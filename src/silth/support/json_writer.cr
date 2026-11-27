require "json"

class JSON::Builder
  # :nodoc: writes an already valid JSON value (a Silth model, a time) straight
  # into the output, with the builder's commas and state.
  def __silth_raw(& : IO ->) : Nil
    scalar { yield @io }
  end
end

module Silth
  # :nodoc: writes JSON values straight into an IO, without `JSON::Builder`'s
  # state machine: models serialize their columns with it (keys are known at
  # compile time), which makes a JSON list cost about what its HTML costs.
  module JSONWriter
    extend self

    def value(io : IO, value : Nil) : Nil
      io << "null"
    end

    def value(io : IO, value : Bool) : Nil
      io << (value ? "true" : "false")
    end

    def value(io : IO, value : Int) : Nil
      io << value
    end

    def value(io : IO, value : Float) : Nil
      raise JSON::Error.new("#{value} not allowed in JSON") unless value.finite?
      io << value
    end

    def value(io : IO, value : String) : Nil
      string(io, value)
    end

    def value(io : IO, value : Time) : Nil
      io << '"'
      time(io, value, JSONTime.digits)
      io << '"'
    end

    def value(io : IO, value : Silth::Decimal | Silth::Date) : Nil
      io << '"' << value << '"' # digits, dots and dashes: nothing to escape
    end

    # Base64, as `Silth::ORM::Cast.write_json` does.
    def value(io : IO, value : Slice(UInt8)) : Nil
      io << '"'
      Base64.strict_encode(value, io)
      io << '"'
    end

    def value(io : IO, value : JSON::Any | Array) : Nil
      value.to_json(io)
    end

    def value(io : IO, value) : Nil
      if value.is_a?(Slice(UInt8))
        value(io, value.as(Slice(UInt8)))
      else
        value.to_json(io)
      end
    end

    # A JSON string: quotes, backslashes and control characters escaped, the rest copied as is.
    def string(io : IO, value : String) : Nil
      io << '"'
      start = cursor = value.to_unsafe
      finish = cursor + value.bytesize
      while cursor < finish
        byte = cursor.value
        if byte >= 0x20 && byte != 0x22 && byte != 0x5c && byte != 0x7f
          cursor += 1
          next
        end
        io.write(Slice.new(start, cursor - start)) if cursor > start
        case byte
        when 0x22 then io << "\\\""
        when 0x5c then io << "\\\\"
        when 0x08 then io << "\\b"
        when 0x0c then io << "\\f"
        when 0x0a then io << "\\n"
        when 0x0d then io << "\\r"
        when 0x09 then io << "\\t"
        else
          io << "\\u00"
          io << '0' if byte < 0x10
          byte.to_s(io, 16)
        end
        cursor += 1
        start = cursor
      end
      io.write(Slice.new(start, cursor - start)) if cursor > start
      io << '"'
    end

    # RFC 3339 in UTC (`2026-11-27T10:00:00.000Z`) with *digits* fractional
    # digits (nil: as many as the value needs, see `JSONTime`).
    def time(io : IO, time : Time, digits : Int32?) : Nil
      utc = time.to_utc
      year, month, day = utc.date
      nanos = utc.nanosecond
      digits ||= nanos == 0 ? 0 : (nanos % 1_000_000 == 0 ? 3 : (nanos % 1_000 == 0 ? 6 : 9))
      return io << utc.to_rfc3339(fraction_digits: digits) unless 0 <= year <= 9999
      storage = uninitialized UInt8[30]
      buffer = storage.to_unsafe
      pos = digits(buffer, 0, year, 4)
      buffer[pos] = '-'.ord.to_u8
      pos = digits(buffer, pos + 1, month, 2)
      buffer[pos] = '-'.ord.to_u8
      pos = digits(buffer, pos + 1, day, 2)
      buffer[pos] = 'T'.ord.to_u8
      pos = digits(buffer, pos + 1, utc.hour, 2)
      buffer[pos] = ':'.ord.to_u8
      pos = digits(buffer, pos + 1, utc.minute, 2)
      buffer[pos] = ':'.ord.to_u8
      pos = digits(buffer, pos + 1, utc.second, 2)
      if digits > 0
        buffer[pos] = '.'.ord.to_u8
        pos = digits(buffer, pos + 1, nanos // 10 ** (9 - digits), digits)
      end
      buffer[pos] = 'Z'.ord.to_u8
      io.write(Slice.new(buffer, pos + 1))
    end

    # Writes *number* on *width* digits at *pos*; returns the next position.
    private def digits(buffer : Pointer(UInt8), pos : Int32, number : Int32, width : Int32) : Int32
      i = pos + width - 1
      while i >= pos
        buffer[i] = (48 + number % 10).to_u8
        number //= 10
        i -= 1
      end
      pos + width
    end
  end
end
