require "socket"
require "openssl"
require "digest/sha1"
require "digest/sha256"
require "./mysql/codec"
require "./mysql/rsa"
require "./mysql/ed25519"

module Silth::DB::MySQL
  # Native MySQL / MariaDB driver (client/server protocol 4.1).
  #
  # Queries with parameters run as server-side prepared statements (binary protocol:
  # `COM_STMT_PREPARE` then `COM_STMT_EXECUTE`), kept in a per-connection LRU cache.
  # Queries without parameters use the text protocol (`COM_QUERY`). Statements the
  # server cannot prepare fall back to client-side interpolation with strict escaping.
  #
  # Auth plugins: `mysql_native_password`, `caching_sha2_password` and
  # `sha256_password` (full authentication over TLS, or with the password encrypted
  # with the server's RSA public key on plain TCP), `mysql_clear_password` (TLS
  # only), MariaDB's `ed25519` and `parsec` (Ed25519 signatures of the server's
  # nonce, see `Ed25519`) and auth switch.
  #
  # ```text
  # mysql://user:pass@host:3306/app?ssl=true                        # TLS
  # mysql://user:pass@host:3306/app?statement_cache_size=512        # prepared statements kept per connection (0: close after use)
  # mysql://user:pass@host:3306/app?prepared_statements=false       # client-side interpolation, text protocol only
  # mysql://user:pass@host:3306/app?server_public_key=/etc/mysql/public_key.pem  # pin the RSA key instead of fetching it
  # mysql://user:pass@host:3306/app?allow_cleartext_password=true   # LDAP/PAM accounts on plain TCP (avoid)
  # ```
  class Connection < Silth::DB::Connection
    LE = IO::ByteFormat::LittleEndian

    CLIENT_LONG_PASSWORD      = 0x00000001_u32
    CLIENT_FOUND_ROWS         = 0x00000002_u32
    CLIENT_LONG_FLAG          = 0x00000004_u32
    CLIENT_CONNECT_WITH_DB    = 0x00000008_u32
    CLIENT_PROTOCOL_41        = 0x00000200_u32
    CLIENT_SSL                = 0x00000800_u32
    CLIENT_TRANSACTIONS       = 0x00002000_u32
    CLIENT_SECURE_CONNECTION  = 0x00008000_u32
    CLIENT_MULTI_STATEMENTS   = 0x00010000_u32
    CLIENT_MULTI_RESULTS      = 0x00020000_u32
    CLIENT_PLUGIN_AUTH        = 0x00080000_u32
    CLIENT_PLUGIN_AUTH_LENENC = 0x00200000_u32

    SERVER_MORE_RESULTS     = 0x0008
    SERVER_NO_BACKSLASH_ESC = 0x0200

    COM_QUIT         = 0x01_u8
    COM_QUERY        = 0x03_u8
    COM_STMT_PREPARE = 0x16_u8
    COM_STMT_CLOSE   = 0x19_u8

    # caching_sha2_password / sha256_password exchanges
    FAST_AUTH_SUCCESS           = 3_u8
    PERFORM_FULL_AUTHENTICATION = 4_u8
    CACHING_SHA2_REQUEST_KEY    = 2_u8
    SHA256_REQUEST_KEY          = 1_u8

    # MariaDB `parsec`: PBKDF2 rounds are 1024 << factor; a larger factor is refused
    # rather than letting a server make the client spin.
    PARSEC_MAX_FACTOR = 10

    # Server errors handled by the prepared statement path
    ER_UNSUPPORTED_PS                  = "1295"
    ER_MAX_PREPARED_STMT_COUNT_REACHED = "1461"
    ER_NEED_REPREPARE                  = "1615"

    DEFAULT_STATEMENT_CACHE_SIZE = 256

    # A server-side prepared statement.
    record Statement, id : UInt32, params : Int32

    # Driver options read from the connection URL query string.
    record Options, prepared_statements : Bool = true, statement_cache_size : Int32 = DEFAULT_STATEMENT_CACHE_SIZE,
      server_public_key : String? = nil, allow_cleartext_password : Bool = false do
      def self.parse(params : URI::Params) : Options
        prepared = !%w(false 0 no off).includes?(params["prepared_statements"]? || "")
        cleartext = %w(true 1 yes on).includes?(params["allow_cleartext_password"]? || "")
        cache_size = DEFAULT_STATEMENT_CACHE_SIZE
        if size = params["statement_cache_size"]?
          cache_size = size.to_i?.try { |n| n >= 0 ? n : nil } ||
                       raise ConnectionError.new("Invalid statement_cache_size '#{size}' (expected an integer >= 0)")
        end
        key = params["server_public_key"]?.try do |path|
          File.read(path) rescue raise ConnectionError.new("Cannot read MySQL server public key #{path}")
        end
        new(prepared, cache_size, key, cleartext)
      end
    end

    getter server_version = ""
    getter options : Options
    @io : IO
    @seq = 0_u8
    @closed = false
    @tls = false
    @no_backslash_escapes = false
    @dialect = Dialect::MySQL.new
    @mutex = Mutex.new
    @statements = {} of String => Statement
    @public_key_requested = false

    def initialize(url : URI)
      host = url.host.presence || "localhost"
      port = url.port || 3306
      user = url.user.presence.try { |u| URI.decode_www_form(u) } || "root"
      password = url.password.try { |p| URI.decode_www_form(p) } || ""
      database = url.path.lchop('/').presence
      params = url.query_params
      want_tls = %w(true required require 1 verify).includes?(params["ssl"]? || params["sslmode"]? || "")
      @options = Options.parse(params)

      socket = begin
        TCPSocket.new(host, port, connect_timeout: 5.seconds)
      rescue ex : ::Socket::Error
        raise ConnectionError.new("Cannot connect to MySQL at #{host}:#{port}: #{ex.message}")
      end
      socket.tcp_nodelay = true
      socket.sync = false
      @io = socket

      begin
        handshake(socket, host, user, password, database, want_tls)
      rescue ex
        @io.close rescue nil
        raise ex
      end
      exec_script("SET NAMES utf8mb4; SET time_zone = '+00:00'")
    end

    # False when the URL has `prepared_statements=false`: every query is interpolated.
    def prepared_statements? : Bool
      @options.prepared_statements
    end

    # Prepared statements kept open per connection (least recently used are closed).
    def statement_cache_size : Int32
      @options.statement_cache_size
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
        write_packet(Bytes[COM_QUIT])
      rescue
      end
      @io.close rescue nil
    end

    # Number of prepared statements currently open on this connection.
    def cached_statement_count : Int32
      @statements.size
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

      auth = auth_response(plugin, password, scramble)
      response = IO::Memory.new
      response.write_bytes(flags, LE)
      response.write_bytes(16_777_216_u32, LE)
      response.write_byte(45_u8) # utf8mb4_general_ci
      response.write(Bytes.new(23))
      response << user
      response.write_byte(0_u8)
      Codec.write_lenenc_bytes(response, auth)
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
        when 0xFE # AuthSwitchRequest: another plugin, with a new scramble
          io = IO::Memory.new(packet[1..])
          plugin = io.gets('\0', chomp: true) || "mysql_native_password"
          rest = io.gets_to_end.to_slice
          scramble = switch_scramble(plugin, rest)
          write_packet(auth_response(plugin, password, scramble))
        when 0x01 # AuthMoreData
          if plugin == "parsec"
            write_packet(parsec_signature(packet[1..], password, scramble))
          else
            auth_more_data(plugin, packet[1..], password, scramble)
          end
        else
          # MariaDB sends plugin data as is unless its first byte could be read as
          # a status (then it is prefixed with 0x01): parsec's salt starts with 'P'.
          raise ConnectionError.new("Unexpected MySQL auth packet 0x#{packet[0].to_s(16)}") unless plugin == "parsec"
          write_packet(parsec_signature(packet, password, scramble))
        end
      end
    end

    # The nonce an AuthSwitchRequest carries: 32 bytes for MariaDB's Ed25519
    # plugins (any byte, NUL included), a 20-byte scramble otherwise.
    private def switch_scramble(plugin : String, data : Bytes) : Bytes
      size = plugin.in?("client_ed25519", "parsec") ? 32 : 20
      data.size >= size ? data[0, size] : data
    end

    # First answer to the server for *plugin*.
    private def auth_response(plugin : String, password : String, scramble : Bytes) : Bytes
      case plugin
      when "client_ed25519" # an empty password is signed too
        return scramble.size == 32 ? Ed25519.sign(scramble, password.to_slice) : Bytes.new(0)
      when "parsec" # an empty packet asks for the salt
        return Bytes.new(0)
      end
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
      when "sha256_password"
        full_auth_payload(password, scramble, request_key: SHA256_REQUEST_KEY)
      when "mysql_clear_password"
        cleartext_password(password)
      when "mysql_native_password", ""
        s1 = digest_sha1(password.to_slice)
        s2 = digest_sha1(s1)
        joined = Bytes.new(scramble.size + s2.size)
        scramble.copy_to(joined)
        s2.copy_to(joined + scramble.size)
        s3 = digest_sha1(joined)
        Bytes.new(s1.size) { |i| s1[i] ^ s3[i] }
      else
        # GSSAPI, PAM dialog…: fail clearly instead of answering with a native hash
        # the server can only reject.
        raise ConnectionError.new("MySQL authentication plugin #{plugin} is not supported " \
                                  "(supported: mysql_native_password, caching_sha2_password, sha256_password, mysql_clear_password, " \
                                  "client_ed25519, parsec). See https://silth.dev/docs/database/mysql#authentication")
      end
    end

    # MariaDB `parsec`, once the server sent its salt (`'P'`, an iteration factor,
    # the salt): the key is PBKDF2-HMAC-SHA512(password, salt, 1024 << factor); the
    # answer is a client nonce and the Ed25519 signature of both nonces.
    private def parsec_signature(salt_packet : Bytes, password : String, server_nonce : Bytes) : Bytes
      unless salt_packet.size > 2 && salt_packet[0] == 'P'.ord && server_nonce.size == 32
        raise ConnectionError.new("MySQL parsec authentication: unexpected salt from the server")
      end
      factor = salt_packet[1]
      raise ConnectionError.new("MySQL parsec authentication: iteration factor #{factor} is too large") if factor > PARSEC_MAX_FACTOR
      key = OpenSSL::PKCS5.pbkdf2_hmac(password, salt_packet[2..], 1024 << factor, OpenSSL::Algorithm::SHA512, 32)
      client_nonce = Random::Secure.random_bytes(32)
      message = Bytes.new(64)
      server_nonce.copy_to(message)
      client_nonce.copy_to(message + 32)
      answer = Bytes.new(96)
      client_nonce.copy_to(answer)
      Ed25519.sign(message, key).copy_to(answer + 32)
      answer
    end

    # `mysql_clear_password` (LDAP/PAM accounts) sends the password as is: only over
    # TLS, or when the URL opts in with `allow_cleartext_password=true`. Otherwise a
    # man in the middle could ask for it with an auth switch and read it.
    private def cleartext_password(password : String) : Bytes
      unless @tls || @options.allow_cleartext_password
        raise ConnectionError.new("MySQL server asked for the cleartext password over an unencrypted connection; " \
                                  "use TLS (?ssl=true) or allow it explicitly with ?allow_cleartext_password=true")
      end
      (password + "\0").to_slice
    end

    # AuthMoreData: a caching_sha2_password status byte, or the RSA public key we asked for.
    private def auth_more_data(plugin : String, data : Bytes, password : String, scramble : Bytes) : Nil
      if plugin == "caching_sha2_password" && data.size == 1
        case data[0]
        when FAST_AUTH_SUCCESS # the OK packet follows
        when PERFORM_FULL_AUTHENTICATION
          write_packet(full_auth_payload(password, scramble, request_key: CACHING_SHA2_REQUEST_KEY))
        else
          raise ConnectionError.new("Unexpected caching_sha2_password status #{data[0]}")
        end
      elsif @public_key_requested
        @public_key_requested = false
        write_packet(RSA.encrypt_password(password, scramble, String.new(data)))
      else
        # Never encrypt the password with a key we did not ask for: over TLS or with a
        # pinned key, that would hand the password to whoever sent it.
        raise ConnectionError.new("MySQL authentication: unexpected public key or data from the server (#{plugin})")
      end
    end

    # The password itself: in clear over TLS, RSA-encrypted with the pinned server key,
    # or a request for the server's public key (answered with AuthMoreData).
    private def full_auth_payload(password : String, scramble : Bytes, request_key : UInt8) : Bytes
      if @tls
        (password + "\0").to_slice
      elsif key = @options.server_public_key
        RSA.encrypt_password(password, scramble, key)
      else
        @public_key_requested = true
        Bytes[request_key]
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

    # Runs *sql*: prepared statement when there are parameters, text protocol otherwise.
    def query(sql : String, args : Array(Value)) : ResultSet
      @mutex.synchronize do
        if args.empty? || !prepared_statements?
          run(interpolate(sql, args))
        else
          run_prepared(sql, args)
        end
      end
    end

    def exec_script(sql : String) : Nil
      @mutex.synchronize { run(sql) }
    end

    private def run(sql : String) : ResultSet
      @seq = 0_u8
      payload = IO::Memory.new
      payload.write_byte(COM_QUERY)
      payload << sql
      write_packet(payload.to_slice)
      read_results(sql, binary: false)
    end

    # --- prepared statements -------------------------------------------------

    private def run_prepared(sql : String, args : Array(Value)) : ResultSet
      execute_cached(sql, args)
    ensure
      trim_statement_cache unless @closed
    end

    private def execute_cached(sql : String, args : Array(Value)) : ResultSet
      stmt = statement(sql) || return run(interpolate(sql, args))
      execute(stmt, sql, args)
    rescue ex : QueryError
      # The server could not re-prepare the statement after a schema change: start over.
      raise ex unless ex.code == ER_NEED_REPREPARE
      discard_statement(sql)
      stmt = statement(sql) || return run(interpolate(sql, args))
      execute(stmt, sql, args)
    end

    # The prepared statement for *sql* (prepared on a cache miss), or nil when the
    # server refuses to prepare it and the query must be interpolated instead.
    private def statement(sql : String) : Statement?
      if stmt = @statements.delete(sql)
        return @statements[sql] = stmt # now the most recently used
      end
      @statements[sql] = prepare(sql)
    rescue ex : QueryError
      raise ex unless ex.code.in?(ER_UNSUPPORTED_PS, ER_MAX_PREPARED_STMT_COUNT_REACHED)
      nil
    end

    private def prepare(sql : String) : Statement
      @seq = 0_u8
      payload = IO::Memory.new
      payload.write_byte(COM_STMT_PREPARE)
      payload << sql
      write_packet(payload.to_slice)
      packet = read_packet
      raise build_error(packet, sql) if packet[0] == 0xFF
      io = IO::Memory.new(packet[1..])
      id = io.read_bytes(UInt32, LE)
      columns = io.read_bytes(UInt16, LE).to_i
      params = io.read_bytes(UInt16, LE).to_i
      skip_definitions(params)
      skip_definitions(columns)
      Statement.new(id, params)
    end

    # Column definitions sent by COM_STMT_PREPARE (resent with every execution).
    private def skip_definitions(count : Int32) : Nil
      return if count == 0
      count.times { read_packet }
      read_packet # EOF
    end

    private def execute(stmt : Statement, sql : String, args : Array(Value)) : ResultSet
      unless stmt.params == args.size
        raise Error.new("SQL expects #{stmt.params} parameter(s), got #{args.size}: #{sql[0, 200]}")
      end
      @seq = 0_u8
      write_packet(Codec.execute_payload(stmt.id, args))
      read_results(sql, binary: true)
    end

    private def trim_statement_cache : Nil
      while @statements.size > statement_cache_size
        _sql, stmt = @statements.shift
        close_statement(stmt)
      end
    end

    private def discard_statement(sql : String) : Nil
      @statements.delete(sql).try { |stmt| close_statement(stmt) }
    end

    # COM_STMT_CLOSE has no response.
    private def close_statement(stmt : Statement) : Nil
      @seq = 0_u8
      payload = IO::Memory.new(5)
      payload.write_byte(COM_STMT_CLOSE)
      payload.write_bytes(stmt.id, LE)
      write_packet(payload.to_slice)
    end

    # --- results -------------------------------------------------------------

    # Reads OK packets and result sets until the server has no more results.
    private def read_results(sql : String, binary : Bool) : ResultSet
      result = ResultSet.new
      loop do
        packet = read_packet
        more = case packet[0]
               when 0x00
                 read_ok(packet, result)
               when 0xFF
                 raise build_error(packet, sql)
               else
                 columns, rows, more_results = read_result_set(packet, sql, binary)
                 result = ResultSet.new(columns.map(&.name), rows) if result.columns.empty?
                 more_results
               end
        break unless more
      end
      result
    end

    # Applies an OK packet to *result*; returns true when more results follow.
    private def read_ok(packet : Bytes, result : ResultSet) : Bool
      io = IO::Memory.new(packet[1..])
      result.rows_affected = Codec.read_lenenc_int(io).to_i64
      last_id = Codec.read_lenenc_int(io).to_i64
      result.last_insert_id = last_id if last_id > 0
      server_status(io.read_bytes(UInt16, LE))
    end

    private def read_result_set(header : Bytes, sql : String, binary : Bool) : {Array(Column), Array(Array(Value)), Bool}
      count = Codec.read_lenenc_int(IO::Memory.new(header)).to_i
      columns = Array(Column).new(count) { parse_column(read_packet) }
      read_packet # EOF after column definitions
      rows = [] of Array(Value)
      loop do
        row = read_packet
        if row[0] == 0xFE && row.size < 9
          return {columns, rows, server_status(IO::Memory.new(row[3, 2]).read_bytes(UInt16, LE))}
        elsif row[0] == 0xFF
          raise build_error(row, sql)
        end
        rows << (binary ? Codec.decode_binary_row(row, columns) : Codec.decode_text_row(row, columns))
      end
    end

    # Records server status flags; returns true when more results follow.
    private def server_status(status : UInt16) : Bool
      @no_backslash_escapes = status & SERVER_NO_BACKSLASH_ESC != 0
      status & SERVER_MORE_RESULTS != 0
    end

    private def parse_column(packet : Bytes) : Column
      io = IO::Memory.new(packet)
      4.times { Codec.read_lenenc_str(io) } # catalog, schema, table, org_table
      name = Codec.read_lenenc_str(io)
      Codec.read_lenenc_str(io) # org_name
      Codec.read_lenenc_int(io) # length of the fixed fields
      charset = io.read_bytes(UInt16, LE)
      length = io.read_bytes(UInt32, LE)
      type = io.read_byte || 0_u8
      flags = io.read_bytes(UInt16, LE)
      decimals = io.read_byte || 0_u8
      Column.new(name, type, charset, length, flags, decimals)
    end

    # --- parameter interpolation ------------------------------------------

    # Inlines *args* into *sql* with strict escaping (used without prepared statements).
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
      when Nil          then io << "NULL"
      when Bool         then io << (value ? '1' : '0')
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
          when '\0'     then io << "\\0"
          when '\''     then io << "\\'"
          when '"'      then io << "\\\""
          when '\b'     then io << "\\b"
          when '\n'     then io << "\\n"
          when '\r'     then io << "\\r"
          when '\t'     then io << "\\t"
          when '\u001a' then io << "\\Z"
          when '\\'     then io << "\\\\"
          else               io << c
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
      when 1062, 1586             then UniqueViolation.new(text, code.to_s, sql)
      when 1451, 1452, 1216, 1217 then ForeignKeyViolation.new(text, code.to_s, sql)
      when 1048, 1364             then NotNullViolation.new(text, code.to_s, sql)
      when 1213, 1205             then SerializationFailure.new(text, code.to_s, sql)
      else                             QueryError.new(text, code.to_s, sql)
      end
    end
  end
end
