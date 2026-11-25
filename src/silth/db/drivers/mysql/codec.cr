module Silth::DB::MySQL
  # Column definition sent by the server before the rows of a result set.
  record Column, name : String, type : UInt8, charset : UInt16, length : UInt32, flags : UInt16 = 0_u16, decimals : UInt8 = 0_u8 do
    def unsigned? : Bool
      flags & Codec::UNSIGNED_FLAG != 0
    end

    # Binary strings (BLOB, BINARY, VARBINARY) use the `binary` character set (63).
    def binary? : Bool
      charset == Codec::BINARY_CHARSET
    end
  end

  # Wire encoding of values for the text protocol (`COM_QUERY`) and the binary
  # protocol of prepared statements (`COM_STMT_EXECUTE`).
  #
  # Both protocols decode to the same Crystal values, so a query returns identical
  # rows whether it ran with parameters (prepared) or without (text).
  #
  # ```
  # payload = Codec.execute_payload(statement_id, [42, "Ada", nil] of Value)
  # row = Codec.decode_binary_row(packet, columns) # => [42, "Ada", nil]
  # ```
  module Codec
    extend self

    LE = IO::ByteFormat::LittleEndian

    COM_STMT_EXECUTE = 0x17_u8

    UNSIGNED_FLAG  = 0x0020_u16
    BINARY_CHARSET =     63_u16

    TYPE_DECIMAL     = 0x00_u8
    TYPE_TINY        = 0x01_u8
    TYPE_SHORT       = 0x02_u8
    TYPE_LONG        = 0x03_u8
    TYPE_FLOAT       = 0x04_u8
    TYPE_DOUBLE      = 0x05_u8
    TYPE_NULL        = 0x06_u8
    TYPE_TIMESTAMP   = 0x07_u8
    TYPE_LONGLONG    = 0x08_u8
    TYPE_INT24       = 0x09_u8
    TYPE_DATE        = 0x0a_u8
    TYPE_TIME        = 0x0b_u8
    TYPE_DATETIME    = 0x0c_u8
    TYPE_YEAR        = 0x0d_u8
    TYPE_VARCHAR     = 0x0f_u8
    TYPE_BIT         = 0x10_u8
    TYPE_JSON        = 0xf5_u8
    TYPE_NEWDECIMAL  = 0xf6_u8
    TYPE_TINY_BLOB   = 0xf9_u8
    TYPE_MEDIUM_BLOB = 0xfa_u8
    TYPE_LONG_BLOB   = 0xfb_u8
    TYPE_BLOB        = 0xfc_u8
    TYPE_VAR_STRING  = 0xfd_u8
    TYPE_STRING      = 0xfe_u8

    # --- result rows ---------------------------------------------------------

    # Decodes a text protocol row: every value is a length-encoded string (0xFB = NULL).
    def decode_text_row(packet : Bytes, columns : Array(Column)) : Array(Value)
      io = IO::Memory.new(packet)
      Array(Value).new(columns.size) do |i|
        if io.peek.try(&.first?) == 0xFB
          io.skip(1)
          nil
        else
          decode_text(read_lenenc_bytes(io), columns[i])
        end
      end
    end

    # Decodes a binary protocol row: `0x00`, a NULL bitmap (offset 2), then the
    # non-NULL values in their binary encoding.
    def decode_binary_row(packet : Bytes, columns : Array(Column)) : Array(Value)
      io = IO::Memory.new(packet)
      io.skip(1)
      bitmap = Bytes.new((columns.size + 9) // 8)
      io.read_fully(bitmap)
      Array(Value).new(columns.size) do |i|
        bit = i + 2
        bitmap[bit // 8] & (1 << (bit % 8)) != 0 ? nil : decode_binary(io, columns[i])
      end
    end

    def decode_text(raw : Bytes, col : Column) : Value
      case col.type
      when TYPE_TINY, TYPE_SHORT, TYPE_LONG, TYPE_INT24, TYPE_YEAR
        text = String.new(raw)
        text.to_i32? || text.to_i64
      when TYPE_LONGLONG
        text = String.new(raw)
        text.to_i64? || text.to_u64.to_i64!
      when TYPE_FLOAT                                 then String.new(raw).to_f32
      when TYPE_DOUBLE, TYPE_DECIMAL, TYPE_NEWDECIMAL then String.new(raw).to_f64
      when TYPE_TIMESTAMP, TYPE_DATE, TYPE_DATETIME
        text = String.new(raw)
        text.starts_with?("0000-00-00") ? nil : DB.parse_time(text)
      when TYPE_JSON then JSON.parse(String.new(raw))
      when TYPE_TINY_BLOB, TYPE_MEDIUM_BLOB, TYPE_LONG_BLOB, TYPE_BLOB, TYPE_VAR_STRING, TYPE_STRING, TYPE_VARCHAR
        col.binary? ? raw : String.new(raw)
      when TYPE_BIT then raw.reduce(0_i64) { |acc, b| (acc << 8) | b }
      else               String.new(raw)
      end
    end

    def decode_binary(io : IO, col : Column) : Value
      case col.type
      when TYPE_TINY  then col.unsigned? ? io.read_bytes(UInt8, LE).to_i32 : io.read_bytes(Int8, LE).to_i32
      when TYPE_SHORT then col.unsigned? ? io.read_bytes(UInt16, LE).to_i32 : io.read_bytes(Int16, LE).to_i32
      when TYPE_YEAR  then io.read_bytes(UInt16, LE).to_i32
      when TYPE_LONG, TYPE_INT24
        if col.unsigned?
          value = io.read_bytes(UInt32, LE)
          value > Int32::MAX ? value.to_i64 : value.to_i32
        else
          io.read_bytes(Int32, LE)
        end
      when TYPE_LONGLONG                            then col.unsigned? ? io.read_bytes(UInt64, LE).to_i64! : io.read_bytes(Int64, LE)
      when TYPE_FLOAT                               then io.read_bytes(Float32, LE)
      when TYPE_DOUBLE                              then io.read_bytes(Float64, LE)
      when TYPE_DATE, TYPE_DATETIME, TYPE_TIMESTAMP then read_binary_datetime(io)
      when TYPE_TIME                                then read_binary_time(io, col)
      when TYPE_NULL                                then nil
      else                                               decode_text(read_lenenc_bytes(io), col)
      end
    end

    # DATE/DATETIME/TIMESTAMP: a length (0, 4, 7 or 11) then the components.
    # Zero dates (`0000-00-00`) decode to nil, like the text protocol.
    private def read_binary_datetime(io : IO) : Time?
      length = io.read_bytes(UInt8, LE)
      return nil if length == 0
      year = io.read_bytes(UInt16, LE).to_i
      month = io.read_bytes(UInt8, LE).to_i
      day = io.read_bytes(UInt8, LE).to_i
      hour = minute = second = micro = 0
      if length >= 7
        hour = io.read_bytes(UInt8, LE).to_i
        minute = io.read_bytes(UInt8, LE).to_i
        second = io.read_bytes(UInt8, LE).to_i
      end
      micro = io.read_bytes(UInt32, LE).to_i if length >= 11
      return nil if year == 0 || month == 0 || day == 0
      Time.utc(year, month, day, hour, minute, second, nanosecond: micro * 1000)
    end

    # TIME: a length (0, 8 or 12), sign, days and clock components. Returns the same
    # `[-]HH:MM:SS[.ffffff]` string as the text protocol.
    private def read_binary_time(io : IO, col : Column) : String
      length = io.read_bytes(UInt8, LE)
      negative = false
      hours = minutes = seconds = micro = 0
      if length >= 8
        negative = io.read_bytes(UInt8, LE) == 1
        hours = io.read_bytes(UInt32, LE).to_i * 24 + io.read_bytes(UInt8, LE)
        minutes = io.read_bytes(UInt8, LE).to_i
        seconds = io.read_bytes(UInt8, LE).to_i
      end
      micro = io.read_bytes(UInt32, LE).to_i if length >= 12
      digits = col.decimals.to_i
      digits = micro > 0 ? 6 : 0 if digits > 6
      String.build do |s|
        s << '-' if negative
        s << hours.to_s.rjust(2, '0') << ':' << minutes.to_s.rjust(2, '0') << ':' << seconds.to_s.rjust(2, '0')
        s << '.' << micro.to_s.rjust(6, '0')[0, digits] if digits > 0
      end
    end

    # --- statement parameters ------------------------------------------------

    # Builds a `COM_STMT_EXECUTE` packet binding *args* to the prepared statement.
    def execute_payload(statement_id : UInt32, args : Array(Value)) : Bytes
      values = args.map { |v| normalize(v) }
      io = IO::Memory.new
      io.write_byte(COM_STMT_EXECUTE)
      io.write_bytes(statement_id, LE)
      io.write_byte(0_u8)       # CURSOR_TYPE_NO_CURSOR
      io.write_bytes(1_u32, LE) # iteration count
      return io.to_slice if values.empty?
      io.write(null_bitmap(values))
      io.write_byte(1_u8) # new_params_bound_flag: parameter types follow
      values.each do |value|
        io.write_byte(param_type(value))
        io.write_byte(0_u8) # signed
      end
      values.each { |value| write_param(io, value) }
      io.to_slice
    end

    # MySQL cannot store NaN or Infinity: send NULL, like the text protocol did.
    private def normalize(value : Value) : Value
      case value
      when Float32, Float64 then value.finite? ? value : nil
      else                       value
      end
    end

    private def null_bitmap(values : Array(Value)) : Bytes
      bitmap = Bytes.new((values.size + 7) // 8)
      values.each_with_index { |v, i| bitmap[i // 8] |= (1_u8 << (i % 8)) if v.nil? }
      bitmap
    end

    def param_type(value : Value) : UInt8
      case value
      when Nil              then TYPE_NULL
      when Bool             then TYPE_TINY
      when Int32            then TYPE_LONG
      when Int64            then TYPE_LONGLONG
      when Float32, Float64 then TYPE_DOUBLE
      when Time             then TYPE_DATETIME
      when Bytes            then TYPE_BLOB # binary character set on the server
      else                       TYPE_STRING
      end
    end

    def write_param(io : IO, value : Value) : Nil
      case value
      when Nil     then nil
      when Bool    then io.write_byte(value ? 1_u8 : 0_u8)
      when Int32   then io.write_bytes(value, LE)
      when Int64   then io.write_bytes(value, LE)
      when Float32 then io.write_bytes(value.to_s.to_f64, LE) # keeps the decimal value ("0.1", not 0.100000001)
      when Float64 then io.write_bytes(value, LE)
      when Time    then write_datetime(io, value.to_utc)
      when Bytes   then write_lenenc_bytes(io, value)
      when String  then write_lenenc_bytes(io, value.to_slice)
      else              write_lenenc_bytes(io, value.to_json.to_slice) # JSON::Any, arrays
      end
    end

    private def write_datetime(io : IO, time : Time) : Nil
      io.write_byte(11_u8)
      io.write_bytes(time.year.to_u16, LE)
      io.write_byte(time.month.to_u8)
      io.write_byte(time.day.to_u8)
      io.write_byte(time.hour.to_u8)
      io.write_byte(time.minute.to_u8)
      io.write_byte(time.second.to_u8)
      io.write_bytes((time.nanosecond // 1000).to_u32, LE)
    end

    # --- length-encoded integers and strings ---------------------------------

    def read_lenenc_int(io : IO) : UInt64
      first = io.read_byte || return 0_u64
      case first
      when 0xFC then io.read_bytes(UInt16, LE).to_u64
      when 0xFD
        b = Bytes.new(3)
        io.read_fully(b)
        (b[0].to_u64 | (b[1].to_u64 << 8) | (b[2].to_u64 << 16))
      when 0xFE then io.read_bytes(UInt64, LE)
      else           first.to_u64
      end
    end

    def read_lenenc_bytes(io : IO) : Bytes
      bytes = Bytes.new(read_lenenc_int(io))
      io.read_fully(bytes)
      bytes
    end

    def read_lenenc_str(io : IO) : String
      String.new(read_lenenc_bytes(io))
    end

    def write_lenenc_int(io : IO, value : UInt64) : Nil
      if value < 251
        io.write_byte(value.to_u8)
      elsif value < 65536
        io.write_byte(0xFC_u8)
        io.write_bytes(value.to_u16, LE)
      elsif value < 16_777_216
        io.write_byte(0xFD_u8)
        io.write_byte((value & 0xFF).to_u8)
        io.write_byte(((value >> 8) & 0xFF).to_u8)
        io.write_byte(((value >> 16) & 0xFF).to_u8)
      else
        io.write_byte(0xFE_u8)
        io.write_bytes(value, LE)
      end
    end

    def write_lenenc_bytes(io : IO, bytes : Bytes) : Nil
      write_lenenc_int(io, bytes.size.to_u64)
      io.write(bytes)
    end
  end
end
