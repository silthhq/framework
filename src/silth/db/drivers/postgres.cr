require "socket"
require "openssl"
require "openssl/hmac"
require "digest/md5"
require "digest/sha256"
require "base64"

module Silth::DB::Postgres
  # Native PostgreSQL driver speaking the v3 frontend/backend protocol.
  #
  # Supports TLS (`?sslmode=disable|prefer|require|verify-full`), SCRAM-SHA-256, MD5 and
  # cleartext authentication, the extended query protocol with text parameters,
  # pgvector values and LISTEN/NOTIFY.
  class Connection < Silth::DB::Connection
    BE = IO::ByteFormat::BigEndian

    record Column, name : String, oid : Int32
    record Notification, channel : String, payload : String, pid : Int32

    getter server_params = {} of String => String
    getter notifications = Deque(Notification).new
    @io : IO
    @closed = false
    @dialect = Dialect::Postgres.new
    @vector_oid : Int32? = nil
    @mutex = Mutex.new

    def initialize(url : URI)
      host = url.host.presence || "localhost"
      port = url.port || 5432
      user = url.user.presence.try { |u| URI.decode_www_form(u) } || ENV["PGUSER"]? || ENV["USER"]? || "postgres"
      password = url.password.try { |p| URI.decode_www_form(p) } || ENV["PGPASSWORD"]? || ""
      database = url.path.lchop('/').presence || user
      params = url.query_params
      sslmode = params["sslmode"]? || (host == "localhost" || host == "127.0.0.1" ? "disable" : "prefer")

      socket = begin
        TCPSocket.new(host, port, connect_timeout: 5.seconds)
      rescue ex : ::Socket::Error
        raise ConnectionError.new("Cannot connect to PostgreSQL at #{host}:#{port}: #{ex.message}")
      end
      socket.tcp_nodelay = true
      socket.sync = false
      @io = socket
      @io = negotiate_tls(socket, host, sslmode) unless sslmode == "disable"

      startup(user, database, params["application_name"]? || "silth")
      authenticate(user, password)
      wait_ready
      detect_extensions
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
        message('X') { }
        @io.flush
      rescue
      end
      @io.close rescue nil
    end

    # --- connection setup ------------------------------------------------

    private def negotiate_tls(socket : TCPSocket, host : String, sslmode : String) : IO
      socket.write_bytes(8_i32, BE)
      socket.write_bytes(80877103_i32, BE)
      socket.flush
      answer = socket.read_byte
      if answer == 'S'.ord
        ctx = OpenSSL::SSL::Context::Client.new
        ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE unless sslmode == "verify-full" || sslmode == "verify-ca"
        tls = OpenSSL::SSL::Socket::Client.new(socket, ctx, sync_close: true, hostname: host)
        tls.sync = false
        tls
      elsif sslmode == "require" || sslmode.starts_with?("verify")
        raise ConnectionError.new("PostgreSQL server does not support TLS (sslmode=#{sslmode})")
      else
        socket
      end
    end

    private def startup(user : String, database : String, app_name : String) : Nil
      body = IO::Memory.new
      body.write_bytes(196608_i32, BE)
      {"user" => user, "database" => database, "application_name" => app_name, "client_encoding" => "UTF8", "DateStyle" => "ISO", "TimeZone" => "UTC"}.each do |k, v|
        cstring(body, k)
        cstring(body, v)
      end
      body.write_byte(0_u8)
      @io.write_bytes((body.size + 4).to_i32, BE)
      @io.write(body.to_slice)
      @io.flush
    end

    private def authenticate(user : String, password : String) : Nil
      loop do
        type, data = read_message
        case type
        when 'R'
          io = IO::Memory.new(data)
          code = io.read_bytes(Int32, BE)
          case code
          when 0 then return
          when 3
            message('p') { |b| cstring(b, password) }
            @io.flush
          when 5
            salt = Bytes.new(4)
            io.read_fully(salt)
            inner = Digest::MD5.hexdigest(password + user)
            outer = Digest::MD5.hexdigest(inner.to_slice + salt)
            message('p') { |b| cstring(b, "md5" + outer) }
            @io.flush
          when 10
            scram_sha256(password, String.new(data[4..]))
          else
            raise ConnectionError.new("Unsupported PostgreSQL authentication method (code #{code})")
          end
        when 'E'
          raise ConnectionError.new("PostgreSQL authentication failed: #{parse_error(data)[:message]}")
        else
          raise ConnectionError.new("Unexpected message '#{type}' during authentication")
        end
      end
    end

    private def scram_sha256(password : String, mechanisms : String) : Nil
      unless mechanisms.split('\0').includes?("SCRAM-SHA-256")
        raise ConnectionError.new("Server requires unsupported SASL mechanisms: #{mechanisms}")
      end
      nonce = Base64.strict_encode(Random::Secure.random_bytes(18))
      client_first_bare = "n=,r=#{nonce}"
      client_first = "n,,#{client_first_bare}"
      message('p') do |b|
        cstring(b, "SCRAM-SHA-256")
        b.write_bytes(client_first.bytesize.to_i32, BE)
        b << client_first
      end
      @io.flush

      type, data = read_message
      raise ConnectionError.new("SCRAM: unexpected message #{type}") unless type == 'R'
      server_first = String.new(data[4..])
      attrs = server_first.split(',').to_h { |kv| {kv[0, 1], kv[2..]} }
      server_nonce = attrs["r"]
      raise ConnectionError.new("SCRAM: invalid server nonce") unless server_nonce.starts_with?(nonce)
      salt = Base64.decode(attrs["s"])
      iterations = attrs["i"].to_i

      salted = OpenSSL::PKCS5.pbkdf2_hmac(password, salt, iterations, OpenSSL::Algorithm::SHA256, 32)
      client_key = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, salted, "Client Key")
      stored_key = sha256(client_key)
      without_proof = "c=biws,r=#{server_nonce}"
      auth_message = "#{client_first_bare},#{server_first},#{without_proof}"
      signature = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, stored_key, auth_message)
      proof = Bytes.new(client_key.size) { |i| client_key[i] ^ signature[i] }
      message('p') { |b| b << "#{without_proof},p=#{Base64.strict_encode(proof)}" }
      @io.flush

      type, data = read_message
      raise ConnectionError.new("SCRAM authentication failed: #{parse_error(data)[:message]}") if type == 'E'
      final = String.new(data[4..])
      server_key = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, salted, "Server Key")
      expected = Base64.strict_encode(OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, server_key, auth_message))
      unless final.lchop("v=") == expected
        raise ConnectionError.new("SCRAM: server signature mismatch")
      end
    end

    private def sha256(data : Bytes) : Bytes
      digest = Digest::SHA256.new
      digest.update(data)
      digest.final
    end

    private def wait_ready : Nil
      loop do
        type, data = read_message
        case type
        when 'S'
          io = IO::Memory.new(data)
          @server_params[read_cstring(io)] = read_cstring(io)
        when 'K', 'N', 'R'
          next
        when 'E'
          raise ConnectionError.new(parse_error(data)[:message])
        when 'Z'
          return
        end
      end
    end

    private def detect_extensions : Nil
      result = run_extended("SELECT oid FROM pg_type WHERE typname = 'vector'", [] of Value)
      @vector_oid = result.rows.first?.try(&.first).as?(Int64).try(&.to_i32)
    rescue
      nil
    end

    # --- queries -----------------------------------------------------------

    def query(sql : String, args : Array(Value)) : ResultSet
      @mutex.synchronize { run_extended(sql, args) }
    end

    def exec_script(sql : String) : Nil
      @mutex.synchronize do
        message('Q') { |b| cstring(b, sql) }
        @io.flush
        error = nil
        loop do
          type, data = read_message
          case type
          when 'E' then error = parse_error(data)
          when 'A' then queue_notification(data)
          when 'Z' then break
          end
        end
        if e = error
          raise build_error(e, sql)
        end
      end
    end

    private def run_extended(sql : String, args : Array(Value)) : ResultSet
      message('P') do |b|
        cstring(b, "")
        cstring(b, sql)
        b.write_bytes(0_i16, BE)
      end
      message('B') do |b|
        cstring(b, "")
        cstring(b, "")
        b.write_bytes(0_i16, BE)
        b.write_bytes(args.size.to_i16, BE)
        args.each do |arg|
          if arg.nil?
            b.write_bytes(-1_i32, BE)
          else
            text = encode(arg)
            b.write_bytes(text.bytesize.to_i32, BE)
            b << text
          end
        end
        b.write_bytes(0_i16, BE)
      end
      message('D') do |b|
        b.write_byte('P'.ord.to_u8)
        cstring(b, "")
      end
      message('E') do |b|
        cstring(b, "")
        b.write_bytes(0_i32, BE)
      end
      message('S') { }
      @io.flush

      columns = [] of Column
      rows = [] of Array(Value)
      affected = 0_i64
      error = nil
      loop do
        type, data = read_message
        case type
        when 'T'
          columns = parse_row_description(data)
        when 'D'
          rows << parse_data_row(data, columns) if error.nil?
        when 'C'
          tag = String.new(data[0, data.size - 1])
          affected = tag.split(' ').last.to_i64? || 0_i64
        when 'E'
          error = parse_error(data)
        when 'A'
          queue_notification(data)
        when 'Z'
          break
        end
      end
      if e = error
        raise build_error(e, sql)
      end
      result = ResultSet.new(columns.map(&.name), rows)
      result.rows_affected = affected
      result
    end

    # Blocks until a NOTIFY arrives (after `LISTEN channel`).
    def wait_for_notification(timeout : Time::Span? = nil) : Notification?
      if n = @notifications.shift?
        return n
      end
      if t = timeout
        @io.as?(TCPSocket).try &.read_timeout = t
      end
      loop do
        type, data = read_message
        if type == 'A'
          queue_notification(data)
          return @notifications.shift?
        end
      end
    rescue IO::TimeoutError
      nil
    ensure
      @io.as?(TCPSocket).try &.read_timeout = nil
    end

    private def queue_notification(data : Bytes) : Nil
      io = IO::Memory.new(data)
      pid = io.read_bytes(Int32, BE)
      channel = read_cstring(io)
      payload = read_cstring(io)
      @notifications << Notification.new(channel, payload, pid)
    end

    # --- encoding / decoding -----------------------------------------------

    private def encode(value : Value) : String
      case value
      when Bool          then value ? "t" : "f"
      when Time          then value.to_utc.to_s("%Y-%m-%d %H:%M:%S.%6N+00")
      when Bytes         then "\\x" + value.hexstring
      when JSON::Any     then value.to_json
      when Array(Float32) then "[" + value.join(',') + "]"
      when Array(String) then "{" + value.map { |s| %("#{s.gsub("\\", "\\\\").gsub('"', "\\\"")}") }.join(',') + "}"
      when Array         then "{" + value.join(',') + "}"
      else                    value.to_s
      end
    end

    private def parse_row_description(data : Bytes) : Array(Column)
      io = IO::Memory.new(data)
      count = io.read_bytes(Int16, BE)
      Array(Column).new(count) do
        name = read_cstring(io)
        io.skip(4 + 2) # table oid, attribute number
        oid = io.read_bytes(Int32, BE)
        io.skip(2 + 4 + 2) # type size, modifier, format
        Column.new(name, oid)
      end
    end

    private def parse_data_row(data : Bytes, columns : Array(Column)) : Array(Value)
      io = IO::Memory.new(data)
      count = io.read_bytes(Int16, BE)
      Array(Value).new(count) do |i|
        len = io.read_bytes(Int32, BE)
        if len < 0
          nil
        else
          bytes = Bytes.new(len)
          io.read_fully(bytes)
          decode(String.new(bytes), columns[i]?.try(&.oid) || 25)
        end
      end
    end

    private def decode(text : String, oid : Int32) : Value
      case oid
      when 16                  then text == "t"
      when 20, 26              then text.to_i64
      when 21, 23              then text.to_i32
      when 700                 then text.to_f32
      when 701                 then text.to_f64
      when 1700                then ::Silth::Decimal.parse?(text) || text # NaN, Infinity stay text
      when 114, 3802           then JSON.parse(text)
      when 17                  then text.starts_with?("\\x") ? text[2..].hexbytes : text.to_slice.dup
      when 1082                then ::Silth::Date.parse?(text) || text      # infinity, BC dates stay text
      when 1114, 1184          then DB.parse_time(text)
      when 1000                then parse_array(text).map { |v| v == "t" }.map(&.to_s)
      when 1005, 1007          then parse_array(text).map(&.to_i32)
      when 1016                then parse_array(text).map(&.to_i64)
      when 1021                then parse_array(text).map(&.to_f32)
      when 1022                then parse_array(text).map(&.to_f64)
      when 1009, 1015, 1014, 2951 then parse_array(text)
      else
        if oid == @vector_oid
          text.strip('[').strip(']').split(',').map(&.to_f32)
        else
          text
        end
      end
    end

    # Parses a one dimensional PostgreSQL array literal.
    private def parse_array(text : String) : Array(String)
      inner = text[1...-1]
      return [] of String if inner.empty?
      items = [] of String
      buf = String::Builder.new
      quoted = false
      escaped = false
      inner.each_char do |c|
        if escaped
          buf << c
          escaped = false
        elsif c == '\\'
          escaped = true
        elsif c == '"'
          quoted = !quoted
        elsif c == ',' && !quoted
          items << buf.to_s
          buf = String::Builder.new
        else
          buf << c
        end
      end
      items << buf.to_s
      items
    end

    # --- low level IO ------------------------------------------------------

    private def message(type : Char, & : IO::Memory ->) : Nil
      body = IO::Memory.new
      yield body
      @io.write_byte(type.ord.to_u8)
      @io.write_bytes((body.size + 4).to_i32, BE)
      @io.write(body.to_slice)
    end

    private def read_message : {Char, Bytes}
      type = @io.read_byte || raise IO::EOFError.new("PostgreSQL connection closed")
      len = @io.read_bytes(Int32, BE)
      data = Bytes.new(len - 4)
      @io.read_fully(data)
      {type.unsafe_chr, data}
    rescue ex : IO::Error
      @closed = true
      self.broken = true
      raise ex
    end

    private def cstring(io : IO, value : String) : Nil
      io << value
      io.write_byte(0_u8)
    end

    private def read_cstring(io : IO) : String
      io.gets('\0', chomp: true) || ""
    end

    private def parse_error(data : Bytes) : NamedTuple(code: String, message: String, detail: String?, hint: String?)
      fields = {} of Char => String
      io = IO::Memory.new(data)
      loop do
        kind = io.read_byte
        break if kind.nil? || kind == 0
        fields[kind.unsafe_chr] = read_cstring(io)
      end
      {code: fields['C']? || "", message: fields['M']? || "Unknown error", detail: fields['D']?, hint: fields['H']?}
    end

    private def build_error(e, sql : String) : QueryError
      text = String.build do |s|
        s << e[:message]
        s << " — " << e[:detail] if e[:detail]
        s << " (hint: " << e[:hint] << ')' if e[:hint]
        s << " [" << e[:code] << "] (SQL: " << sql[0, 500] << ')'
      end
      case e[:code]
      when "23505"          then UniqueViolation.new(text, e[:code], sql)
      when "23503"          then ForeignKeyViolation.new(text, e[:code], sql)
      when "23502"          then NotNullViolation.new(text, e[:code], sql)
      when "40001", "40P01" then SerializationFailure.new(text, e[:code], sql)
      else                       QueryError.new(text, e[:code], sql)
      end
    end
  end
end
