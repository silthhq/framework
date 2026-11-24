require "socket"
require "openssl"
require "digest/sha1"
require "digest/sha256"

module Silth::DB::MySQL
  # Native MySQL / MariaDB driver (client/server protocol 4.1, text protocol).
  #
  # Parameters are interpolated client side with strict escaping (the same strategy
  # as PDO's emulated prepares). Auth plugins: `mysql_native_password`,
  # `caching_sha2_password` (fast path, or full auth over TLS) and auth switch.
  class Connection < Silth::DB::Connection
    LE = IO::ByteFormat::LittleEndian

    CLIENT_LONG_PASSWORD     = 0x00000001_u32
    CLIENT_FOUND_ROWS        = 0x00000002_u32
    CLIENT_LONG_FLAG         = 0x00000004_u32
    CLIENT_CONNECT_WITH_DB   = 0x00000008_u32
    CLIENT_PROTOCOL_41       = 0x00000200_u32
    CLIENT_SSL               = 0x00000800_u32
    CLIENT_TRANSACTIONS      = 0x00002000_u32
    CLIENT_SECURE_CONNECTION = 0x00008000_u32
    CLIENT_MULTI_STATEMENTS  = 0x00010000_u32
    CLIENT_MULTI_RESULTS     = 0x00020000_u32
    CLIENT_PLUGIN_AUTH       = 0x00080000_u32
    CLIENT_PLUGIN_AUTH_LENENC = 0x00200000_u32

    SERVER_MORE_RESULTS     = 0x0008
    SERVER_NO_BACKSLASH_ESC = 0x0200

    record Column, name : String, type : UInt8, charset : UInt16, length : UInt32

    getter server_version = ""
    @io : IO
    @seq = 0_u8
    @closed = false
    @tls = false
    @no_backslash_escapes = false
    @dialect = Dialect::MySQL.new
    @mutex = Mutex.new

    def initialize(url : URI)
      host = url.host.presence || "localhost"
      port = url.port || 3306
      user = url.user.presence.try { |u| URI.decode_www_form(u) } || "root"
      password = url.password.try { |p| URI.decode_www_form(p) } || ""
      database = url.path.lchop('/').presence
      params = url.query_params
      want_tls = %w(true required require 1 verify).includes?(params["ssl"]? || params["sslmode"]? || "")

      socket = begin
        TCPSocket.new(host, port, connect_timeout: 5.seconds)
      rescue ex : ::Socket::Error
        raise ConnectionError.new("Cannot connect to MySQL at #{host}:#{port}: #{ex.message}")
      end
      socket.tcp_nodelay = true
      socket.sync = false
      @io = socket

      handshake(socket, host, user, password, database, want_tls)
      exec_script("SET NAMES utf8mb4; SET time_zone = '+00:00'")
    end

    def dialect : Dialect
      @dialect
    end

    def closed? : Bool
      @closed
    end

    def close : Nil
      return if @closed
      @closed = true
      begin
        @seq = 0_u8
        write_packet(Bytes[0x01])
      rescue
      end
      @io.close rescue nil
    end

    # --- handshake ---------------------------------------------------------

    private def handshake(socket : TCPSocket, host : String, user : String, password : String, database : String?, want_tls : Bool) : Nil
      packet = read_packet
      raise ConnectionError.new("MySQL: #{parse_err(packet)}") if packet[0] == 0xFF
      io = IO::Memory.new(packet)
      io.read_byte # protocol version
      @server_version = io.gets('\0', chomp: true) || ""
      io.skip(4)
      auth1 = Bytes.new(8)
      io.read_fully(auth1)
      io.skip(1)
      caps = io.read_bytes(UInt16, LE).to_u32
      io.skip(1 + 2) # charset, status
      caps |= io.read_bytes(UInt16, LE).to_u32 << 16
      auth_len = io.read_byte || 0_u8
      io.skip(10)
      part2_len = {13, auth_len.to_i - 8}.max
      auth2 = Bytes.new(part2_len)
      io.read_fully(auth2)
      scramble = Bytes.new(20)
      auth1.copy_to(scramble)
      auth2[0, 12].copy_to(scramble + 8)
      plugin = io.gets('\0', chomp: true) || "mysql_native_password"

      flags = CLIENT_LONG_PASSWORD | CLIENT_FOUND_ROWS | CLIENT_LONG_FLAG | CLIENT_PROTOCOL_41 | CLIENT_TRANSACTIONS |
              CLIENT_SECURE_CONNECTION | CLIENT_MULTI_STATEMENTS | CLIENT_MULTI_RESULTS | CLIENT_PLUGIN_AUTH | CLIENT_PLUGIN_AUTH_LENENC
      flags |= CLIENT_CONNECT_WITH_DB if database

      if want_tls
        raise ConnectionError.new("MySQL server does not support TLS") if caps & CLIENT_SSL == 0
        flags |= CLIENT_SSL
        ssl_request = IO::Memory.new
        ssl_request.write_bytes(flags, LE)
        ssl_request.write_bytes(16_777_216_u32, LE)
        ssl_request.write_byte(45_u8)
        ssl_request.write(Bytes.new(23))
        write_packet(ssl_request.to_slice)
        ctx = OpenSSL::SSL::Context::Client.new
        ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE
        tls = OpenSSL::SSL::Socket::Client.new(socket, ctx, sync_close: true, hostname: host)
        tls.sync = false
        @io = tls
        @tls = true
      end

      auth = scramble_for(plugin, password, scramble)
      response = IO::Memory.new
      response.write_bytes(flags, LE)
      response.write_bytes(16_777_216_u32, LE)
      response.write_byte(45_u8) # utf8mb4_general_ci
      response.write(Bytes.new(23))
      response << user
      response.write_byte(0_u8)
      write_lenenc_int(response, auth.size.to_u64)
      response.write(auth)
      if db = database
        response << db
        response.write_byte(0_u8)
      end
      response << plugin
      response.write_byte(0_u8)
      write_packet(response.to_slice)
      finish_auth(plugin, password, scramble)
    end

    private def finish_auth(plugin : String, password : String, scramble : Bytes) : Nil
      loop do
        packet = read_packet
        case packet[0]
        when 0x00
          return
        when 0xFF
          raise ConnectionError.new("MySQL authentication failed: #{parse_err(packet)}")
        when 0xFE
          io = IO::Memory.new(packet[1..])
          plugin = io.gets('\0', chomp: true) || "mysql_native_password"
          rest = io.gets_to_end.to_slice
          scramble = rest.size >= 20 ? rest[0, 20] : rest
          write_packet(scramble_for(plugin, password, scramble))
        when 0x01
          if packet.size > 1 && packet[1] == 3
            next # fast auth success, OK packet follows
          elsif packet.size > 1 && packet[1] == 4
            if @tls
              write_packet((password + "\0").to_slice)
            else
              raise ConnectionError.new("caching_sha2_password full authentication requires TLS (add ?ssl=true) or a mysql_native_password user")
            end
          end
        else
          raise ConnectionError.new("Unexpected MySQL auth packet 0x#{packet[0].to_s(16)}")
        end
      end
    end

    private def scramble_for(plugin : String, password : String, scramble : Bytes) : Bytes
      return Bytes.new(0) if password.empty?
      case plugin
      when "caching_sha2_password"
        p1 = digest_sha256(password.to_slice)
        p2 = digest_sha256(p1)
        joined = Bytes.new(p2.size + scramble.size)
        p2.copy_to(joined)
        scramble.copy_to(joined + p2.size)
        p3 = digest_sha256(joined)
        Bytes.new(p1.size) { |i| p1[i] ^ p3[i] }
      when "mysql_clear_password"
        (password + "\0").to_slice
      else
        s1 = digest_sha1(password.to_slice)
        s2 = digest_sha1(s1)
        joined = Bytes.new(scramble.size + s2.size)
        scramble.copy_to(joined)
        s2.copy_to(joined + scramble.size)
        s3 = digest_sha1(joined)
        Bytes.new(s1.size) { |i| s1[i] ^ s3[i] }
      end
    end

    private def digest_sha1(data : Bytes) : Bytes
      d = Digest::SHA1.new
      d.update(data)
      d.final
    end

    private def digest_sha256(data : Bytes) : Bytes
      d = Digest::SHA256.new
      d.update(data)
      d.final
    end

    # --- queries -----------------------------------------------------------

    def query(sql : String, args : Array(Value)) : ResultSet
      @mutex.synchronize { run(interpolate(sql, args)) }
    end

    def exec_script(sql : String) : Nil
      @mutex.synchronize { run(sql) }
    end

    private def run(sql : String) : ResultSet
      @seq = 0_u8
      payload = IO::Memory.new
      payload.write_byte(0x03_u8)
      payload << sql
      write_packet(payload.to_slice)

      result = ResultSet.new
      loop do
        packet = read_packet
        more = false
        case packet[0]
        when 0x00
          io = IO::Memory.new(packet[1..])
          result.rows_affected = read_lenenc_int(io).to_i64
          last_id = read_lenenc_int(io).to_i64
          result.last_insert_id = last_id if last_id > 0
          status = io.read_bytes(UInt16, LE)
          @no_backslash_escapes = status & SERVER_NO_BACKSLASH_ESC != 0
          more = status & SERVER_MORE_RESULTS != 0
        when 0xFF
          drain_on_error
          raise build_error(packet, sql)
        else
          count = read_lenenc_int(IO::Memory.new(packet)).to_i
          columns = Array(Column).new(count) { parse_column(read_packet) }
          read_packet # EOF after column definitions
          rows = [] of Array(Value)
          loop do
            row = read_packet
            if row[0] == 0xFE && row.size < 9
              status = IO::Memory.new(row[3, 2]).read_bytes(UInt16, LE)
              more = status & SERVER_MORE_RESULTS != 0
              break
            elsif row[0] == 0xFF
              raise build_error(row, sql)
            end
            rows << parse_row(row, columns)
          end
          result = ResultSet.new(columns.map(&.name), rows) if result.columns.empty?
        end
        break unless more
      end
      result
    end

    private def drain_on_error : Nil
    end

    private def parse_column(packet : Bytes) : Column
      io = IO::Memory.new(packet)
      4.times { read_lenenc_str(io) } # catalog, schema, table, org_table
      name = read_lenenc_str(io)
      read_lenenc_str(io) # org_name
      read_lenenc_int(io)
      charset = io.read_bytes(UInt16, LE)
      length = io.read_bytes(UInt32, LE)
      type = io.read_byte || 0_u8
      Column.new(name, type, charset, length)
    end

    private def parse_row(packet : Bytes, columns : Array(Column)) : Array(Value)
      io = IO::Memory.new(packet)
      Array(Value).new(columns.size) do |i|
        if io.peek.try(&.first?) == 0xFB
          io.skip(1)
          nil
        else
          raw = read_lenenc_bytes(io)
          decode(raw, columns[i])
        end
      end
    end

    private def decode(raw : Bytes, col : Column) : Value
      case col.type
      when 0x01, 0x02, 0x03, 0x09, 0x0d then String.new(raw).to_i32
      when 0x08                          then String.new(raw).to_i64? || String.new(raw).to_u64.to_i64!
      when 0x04                          then String.new(raw).to_f32
      when 0x05                          then String.new(raw).to_f64
      when 0x00, 0xf6                    then String.new(raw).to_f64
      when 0x07, 0x0a, 0x0c
        text = String.new(raw)
        text.starts_with?("0000-00-00") ? nil : DB.parse_time(text)
      when 0xf5 then JSON.parse(String.new(raw))
      when 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0x0f
        col.charset == 63 ? raw : String.new(raw)
      when 0x10 then raw.reduce(0_i64) { |acc, b| (acc << 8) | b }
      else           String.new(raw)
      end
    end

    # --- parameter interpolation ------------------------------------------

    def interpolate(sql : String, args : Array(Value)) : String
      return sql if args.empty?
      index = 0
      String.build do |io|
        quote = nil.as(Char?)
        reader = Char::Reader.new(sql)
        while reader.has_next?
          c = reader.current_char
          if quote
            io << c
            if c == '\\' && quote != '`'
              reader.next_char
              io << reader.current_char if reader.has_next?
            elsif c == quote
              quote = nil
            end
          elsif c == '\'' || c == '"' || c == '`'
            quote = c
            io << c
          elsif c == '?'
            raise Error.new("Not enough parameters for SQL: #{sql[0, 200]}") if index >= args.size
            literal(io, args[index])
            index += 1
          else
            io << c
          end
          reader.next_char
        end
      end
    end

    private def literal(io : IO, value : Value) : Nil
      case value
      when Nil   then io << "NULL"
      when Bool  then io << (value ? '1' : '0')
      when Int32, Int64 then io << value
      when Float32, Float64
        io << (value.finite? ? value.to_s : "NULL")
      when String then quote_string(io, value)
      when Time   then io << '\'' << DB.format_time(value) << '\''
      when Bytes  then io << "X'" << value.hexstring << '\''
      else             quote_string(io, value.to_json)
      end
    end

    private def quote_string(io : IO, value : String) : Nil
      io << '\''
      if @no_backslash_escapes
        io << value.gsub('\'', "''")
      else
        value.each_char do |c|
          case c
          when '\0'   then io << "\\0"
          when '\''   then io << "\\'"
          when '"'    then io << "\\\""
          when '\b'   then io << "\\b"
          when '\n'   then io << "\\n"
          when '\r'   then io << "\\r"
          when '\t'   then io << "\\t"
          when '\u001a' then io << "\\Z"
          when '\\'   then io << "\\\\"
          else             io << c
          end
        end
      end
      io << '\''
    end

    # --- packets -----------------------------------------------------------

    private def write_packet(payload : Bytes) : Nil
      offset = 0
      loop do
        chunk = {payload.size - offset, 0xFFFFFF}.min
        header = Bytes[(chunk & 0xFF).to_u8, ((chunk >> 8) & 0xFF).to_u8, ((chunk >> 16) & 0xFF).to_u8, @seq]
        @io.write(header)
        @io.write(payload[offset, chunk])
        @seq &+= 1
        offset += chunk
        break if chunk < 0xFFFFFF
      end
      @io.flush
    rescue ex : IO::Error
      @closed = true
      self.broken = true
      raise ex
    end

    private def read_packet : Bytes
      buffer = IO::Memory.new
      loop do
        header = Bytes.new(4)
        @io.read_fully(header)
        len = header[0].to_i | (header[1].to_i << 8) | (header[2].to_i << 16)
        @seq = header[3] &+ 1
        chunk = Bytes.new(len)
        @io.read_fully(chunk)
        buffer.write(chunk)
        break if len < 0xFFFFFF
      end
      buffer.to_slice
    rescue ex : IO::Error
      @closed = true
      self.broken = true
      raise ex
    end

    private def read_lenenc_int(io : IO) : UInt64
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

    private def read_lenenc_bytes(io : IO) : Bytes
      len = read_lenenc_int(io)
      bytes = Bytes.new(len)
      io.read_fully(bytes)
      bytes
    end

    private def read_lenenc_str(io : IO) : String
      String.new(read_lenenc_bytes(io))
    end

    private def write_lenenc_int(io : IO, value : UInt64) : Nil
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

    private def parse_err(packet : Bytes) : String
      return "unknown error" if packet.size < 3
      io = IO::Memory.new(packet[1..])
      code = io.read_bytes(UInt16, LE)
      rest = io.gets_to_end
      rest = rest[6..] if rest.starts_with?('#')
      "#{rest} (#{code})"
    end

    private def build_error(packet : Bytes, sql : String) : QueryError
      io = IO::Memory.new(packet[1..])
      code = io.read_bytes(UInt16, LE)
      rest = io.gets_to_end
      state = ""
      if rest.starts_with?('#')
        state = rest[1, 5]
        rest = rest[6..]
      end
      text = "#{rest} [#{code}/#{state}] (SQL: #{sql[0, 500]})"
      case code
      when 1062, 1586        then UniqueViolation.new(text, code.to_s, sql)
      when 1451, 1452, 1216, 1217 then ForeignKeyViolation.new(text, code.to_s, sql)
      when 1048, 1364        then NotNullViolation.new(text, code.to_s, sql)
      when 1213, 1205        then SerializationFailure.new(text, code.to_s, sql)
      else                        QueryError.new(text, code.to_s, sql)
      end
    end
  end
end
