require "./spec_helper"

# MySQL / MariaDB driver.
#
# - Codec and RSA specs run everywhere (no server needed).
# - Protocol specs run with `SILTH_TEST_DATABASE_URL=mysql://…`.
# - Authentication specs need an account allowed to create users:
#   `SILTH_TEST_MYSQL_ADMIN_URL=mysql://root:silth@127.0.0.1:53307/silth_test` (MySQL 8+).
module MySQLSpec
  alias MySQL = Silth::DB::MySQL
  alias Codec = Silth::DB::MySQL::Codec
  alias Value = Silth::DB::Value
  LE = IO::ByteFormat::LittleEndian

  def self.url : String?
    ENV["SILTH_TEST_DATABASE_URL"]?.try { |u| u.starts_with?("mysql") || u.starts_with?("mariadb") ? u : nil }
  end

  # Opens a connection to *url*, optionally as another user (without selecting a
  # database: throwaway accounts have no grants) and with extra URL options.
  def self.connect(url : String, user : String? = nil, password : String? = nil, **options) : MySQL::Connection
    uri = URI.parse(url)
    if user
      uri.user = user
      uri.password = password
      uri.path = ""
    end
    params = uri.query_params
    options.each { |key, value| params[key.to_s] = value.to_s }
    uri.query = params.empty? ? nil : params.to_s
    MySQL::Connection.new(uri)
  end

  def self.column(type : UInt8, unsigned = false, charset = 45_u16, decimals = 0_u8) : MySQL::Column
    MySQL::Column.new("c", type, charset, 0_u32, unsigned ? Codec::UNSIGNED_FLAG : 0_u16, decimals)
  end

  # Statements prepared by the client and closed, from the session counters (read with
  # the text protocol). MySQL 8 also counts its own internal re-prepares (a parameter
  # type that differs from the one inferred at prepare time) in Com_stmt_prepare.
  def self.statement_counters(conn : MySQL::Connection) : {Int64, Int64}
    rows = conn.query("SHOW SESSION STATUS WHERE Variable_name IN ('Com_stmt_prepare', 'Com_stmt_reprepare', 'Com_stmt_close')", [] of Value).rows
    counters = rows.to_h { |r| {r[0].to_s, r[1].to_s.to_i64} }
    {counters["Com_stmt_prepare"] - (counters["Com_stmt_reprepare"]? || 0_i64), counters["Com_stmt_close"]}
  end

  def self.openssl(*args : String) : Bytes
    output = IO::Memory.new
    error = IO::Memory.new
    status = Process.run(Process.find_executable("openssl").not_nil!, args.to_a, output: output, error: error)
    raise "openssl #{args.first} failed: #{error}" unless status.success?
    output.to_slice
  end

  # A one-shot fake server: sends a `caching_sha2_password` handshake, reads the
  # client's response, then sends *replies*. Returns the port it listens on.
  def self.fake_server(replies : Array(Bytes)) : Int32
    server = TCPServer.new("127.0.0.1", 0)
    spawn do
      client = server.accept
      handshake = IO::Memory.new
      handshake.write_byte(10_u8)
      handshake << "8.0.0-fake\0"
      handshake.write_bytes(1_u32, LE)       # connection id
      handshake.write(Bytes.new(8, 0x41_u8)) # scramble, part 1
      handshake.write_byte(0_u8)
      handshake.write_bytes(0xFFFF_u16, LE) # capabilities (low)
      handshake.write_byte(45_u8)
      handshake.write_bytes(2_u16, LE)      # status
      handshake.write_bytes(0x00FF_u16, LE) # capabilities (high)
      handshake.write_byte(21_u8)           # scramble length
      handshake.write(Bytes.new(10))
      handshake.write(Bytes.new(12, 0x42_u8)) # scramble, part 2
      handshake.write_byte(0_u8)
      handshake << "caching_sha2_password\0"
      ([handshake.to_slice] + replies).each_with_index do |payload, i|
        client.write(Bytes[payload.size.to_u8, (payload.size >> 8).to_u8, (payload.size >> 16).to_u8, (i * 2).to_u8])
        client.write(payload)
        client.flush
        next unless i == 0
        header = Bytes.new(4) # the client's handshake response
        client.read_fully(header)
        client.skip(header[0].to_i | (header[1].to_i << 8) | (header[2].to_i << 16))
      end
      client.gets rescue nil # wait for the client to hang up
      client.close
      server.close
    end
    server.local_address.port
  end
end

describe Silth::DB::MySQL::Codec do
  it "binds parameters in COM_STMT_EXECUTE (types, NULL bitmap, binary values)" do
    time = Time.utc(2026, 11, 25, 8, 30, 15, nanosecond: 123_456_789)
    args = [nil, true, 42, 5_000_000_000_i64, 0.1_f32, "été", Bytes[0, 255], time, Float64::NAN] of MySQLSpec::Value
    io = IO::Memory.new(MySQLSpec::Codec.execute_payload(7_u32, args))
    le = MySQLSpec::LE

    io.read_byte.should eq(0x17)
    io.read_bytes(UInt32, le).should eq(7)
    io.read_byte.should eq(0)                  # no cursor
    io.read_bytes(UInt32, le).should eq(1)     # iteration count
    io.read_bytes(UInt16, le).should eq(0x101) # NULL bitmap: first and last (NaN) parameters
    io.read_byte.should eq(1)                  # types follow
    Array.new(args.size) { io.read_bytes(UInt16, le) }.should eq([0x06, 0x01, 0x03, 0x08, 0x05, 0xfe, 0xfc, 0x0c, 0x06])
    io.read_byte.should eq(1)
    io.read_bytes(Int32, le).should eq(42)
    io.read_bytes(Int64, le).should eq(5_000_000_000)
    io.read_bytes(Float64, le).should eq(0.1) # decimal value of the Float32, not 0.10000000149
    MySQLSpec::Codec.read_lenenc_str(io).should eq("été")
    MySQLSpec::Codec.read_lenenc_bytes(io).should eq(Bytes[0, 255])
    io.read_byte.should eq(11)
    io.read_bytes(UInt16, le).should eq(2026)
    Bytes.new(5).tap { |b| io.read_fully(b) }.should eq(Bytes[11, 25, 8, 30, 15])
    io.read_bytes(UInt32, le).should eq(123_456) # microseconds
    io.pos.should eq(io.size)
  end

  it "decodes binary rows to the same values as text rows" do
    columns = [
      MySQLSpec.column(MySQLSpec::Codec::TYPE_LONGLONG),
      MySQLSpec.column(MySQLSpec::Codec::TYPE_TINY, unsigned: true),
      MySQLSpec.column(MySQLSpec::Codec::TYPE_LONG, unsigned: true),
      MySQLSpec.column(MySQLSpec::Codec::TYPE_DOUBLE),
      MySQLSpec.column(MySQLSpec::Codec::TYPE_DATETIME, decimals: 6_u8),
      MySQLSpec.column(MySQLSpec::Codec::TYPE_VAR_STRING),
      MySQLSpec.column(MySQLSpec::Codec::TYPE_BLOB, charset: 63_u16),
      MySQLSpec.column(MySQLSpec::Codec::TYPE_VAR_STRING),
      MySQLSpec.column(MySQLSpec::Codec::TYPE_TIME, decimals: 3_u8),
      MySQLSpec.column(MySQLSpec::Codec::TYPE_DATE),
      MySQLSpec.column(MySQLSpec::Codec::TYPE_NEWDECIMAL),
    ]
    time = Time.utc(2026, 11, 25, 8, 30, 15, nanosecond: 123_456_000)
    expected = [-5_i64, 200, 4_000_000_000_i64, 2.5, time, "héllo", Bytes[0, 1, 255], nil, "-26:03:04.500", nil, 12.5] of MySQLSpec::Value
    le = MySQLSpec::LE

    binary = IO::Memory.new
    binary.write_byte(0_u8)
    binary.write(Bytes[0, 2]) # NULL bitmap (offset 2): column 7
    binary.write_bytes(-5_i64, le)
    binary.write_byte(200_u8)
    binary.write_bytes(4_000_000_000_u32, le)
    binary.write_bytes(2.5, le)
    MySQLSpec::Codec.write_param(binary, time)
    MySQLSpec::Codec.write_lenenc_bytes(binary, "héllo".to_slice)
    MySQLSpec::Codec.write_lenenc_bytes(binary, Bytes[0, 1, 255])
    binary.write(Bytes[12, 1, 1, 0, 0, 0, 2, 3, 4]) # negative, 1 day 02:03:04
    binary.write_bytes(500_000_u32, le)
    binary.write(Bytes[4, 0, 0, 0, 0]) # 0000-00-00
    MySQLSpec::Codec.write_lenenc_bytes(binary, "12.50".to_slice)

    text = IO::Memory.new
    ["-5", "200", "4000000000", "2.5", "2026-11-25 08:30:15.123456", "héllo", Bytes[0, 1, 255], nil, "-26:03:04.500", "0000-00-00", "12.50"].each do |value|
      case value
      when Nil    then text.write_byte(0xFB_u8)
      when String then MySQLSpec::Codec.write_lenenc_bytes(text, value.to_slice)
      when Bytes  then MySQLSpec::Codec.write_lenenc_bytes(text, value)
      end
    end

    MySQLSpec::Codec.decode_binary_row(binary.to_slice, columns).should eq(expected)
    MySQLSpec::Codec.decode_text_row(text.to_slice, columns).should eq(expected)
  end
end

describe Silth::DB::MySQL::RSA do
  it "encrypts the scrambled password with RSA-OAEP (both PEM formats)" do
    Process.find_executable("openssl") || pending!("openssl CLI not found")
    dir = File.tempname("silth-rsa", nil)
    Dir.mkdir(dir)
    begin
      private_key = File.join(dir, "private.pem")
      MySQLSpec.openssl("genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", private_key)
      spki = String.new(MySQLSpec.openssl("pkey", "-in", private_key, "-pubout"))
      pkcs1 = String.new(MySQLSpec.openssl("rsa", "-in", private_key, "-RSAPublicKey_out"))
      scramble = Bytes.new(20) { |i| (i * 7 + 3).to_u8 }

      {spki, pkcs1}.each do |pem|
        encrypted = Silth::DB::MySQL::RSA.encrypt_password("s3cr€t", scramble, pem)
        encrypted.size.should eq(256)
        File.write(File.join(dir, "secret.bin"), encrypted)
        plain = MySQLSpec.openssl("pkeyutl", "-decrypt", "-inkey", private_key, "-pkeyopt", "rsa_padding_mode:oaep", "-in", File.join(dir, "secret.bin"))
        revealed = Bytes.new(plain.size) { |i| plain[i] ^ scramble[i % scramble.size] }
        String.new(revealed).should eq("s3cr€t\0")
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "rejects keys that are not PEM public keys" do
    expect_raises(Silth::DB::ConnectionError, /PEM public key/) do
      Silth::DB::MySQL::RSA.encrypt_password("x", Bytes[1, 2, 3], "not a key")
    end
    expect_raises(Silth::DB::ConnectionError, /invalid server public key/) do
      Silth::DB::MySQL::RSA.encrypt_password("x", Bytes[1, 2, 3], "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----")
    end
  end
end

describe "MySQL authentication (fake server)" do
  it "never encrypts the password with a public key it did not ask for" do
    pem = "-----BEGIN PUBLIC KEY-----\nMFwwDQYJKoZIhvcNAQEBBQADSwAwSAJBAL\n-----END PUBLIC KEY-----"
    port = MySQLSpec.fake_server([Bytes[0x01] + pem.to_slice])
    expect_raises(Silth::DB::ConnectionError, /unexpected public key/) do
      MySQLSpec.connect("mysql://app:secret@127.0.0.1:#{port}/app")
    end
  end
end

if url = MySQLSpec.url
  describe "MySQL driver protocol" do
    it "returns the same values through prepared statements and the text protocol" do
      conn = MySQLSpec.connect(url)
      begin
        conn.exec_script(<<-SQL)
          CREATE TEMPORARY TABLE silth_types (
            id BIGINT AUTO_INCREMENT PRIMARY KEY, tiny TINYINT, utiny TINYINT UNSIGNED, flag TINYINT(1),
            small SMALLINT, uint INT UNSIGNED, big BIGINT, ubig BIGINT UNSIGNED, real_value FLOAT, dbl DOUBLE,
            price DECIMAL(10,2), name VARCHAR(100), body LONGTEXT, data LONGBLOB, meta JSON, born DATE,
            at DATETIME(6), stamp TIMESTAMP(6) NULL, span TIME(3), yr YEAR, bits BIT(8), kind ENUM('a','b'), nothing VARCHAR(10))
          SQL
        tricky = "O'Reilly \\ \"quoted\" \0 \n\t ✓ 🚀"
        blob = Bytes.new(256) { |i| i.to_u8 }
        at = Time.utc(2026, 11, 25, 8, 30, 15, nanosecond: 123_456_000)
        insert = conn.query(<<-SQL, [-128, 255, true, -32768, 4_000_000_000_i64, Int64::MIN, 1.5_f32, 2.75, "1234.56", tricky, "x" * 70_000, blob, %({"a":[1,2]}), Time.utc(1999, 12, 31), at, at, "-26:03:04.5", 2026, 5, "b", nil] of MySQLSpec::Value)
          INSERT INTO silth_types (tiny, utiny, flag, small, uint, big, ubig, real_value, dbl, price, name, body, data, meta, born, at, stamp, span, yr, bits, kind, nothing)
          VALUES (?, ?, ?, ?, ?, ?, 18446744073709551615, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
        insert.rows_affected.should eq(1)
        id = insert.last_insert_id.not_nil!

        prepared = conn.query("SELECT * FROM silth_types WHERE id = ?", [id] of MySQLSpec::Value)
        text = conn.query("SELECT * FROM silth_types", [] of MySQLSpec::Value)
        prepared.columns.should eq(text.columns)
        prepared.rows.should eq(text.rows)

        row = prepared.first?.not_nil!
        row["tiny"].should eq(-128)
        row["utiny"].should eq(255)
        row["flag"].should eq(1)
        row["uint"].should eq(4_000_000_000_i64)
        row["big"].should eq(Int64::MIN)
        row["ubig"].should eq(-1_i64) # UInt64::MAX wraps, as with the text protocol
        row["real_value"].should eq(1.5_f32)
        row["dbl"].should eq(2.75)
        row["price"].should eq(1234.56)
        row["name"].should eq(tricky)
        row["body"].as(String).size.should eq(70_000)
        row["data"].should eq(blob)
        row["born"].should eq(Time.utc(1999, 12, 31))
        row["at"].should eq(at)
        row["stamp"].should eq(at)
        row["span"].should eq("-26:03:04.500")
        row["yr"].should eq(2026)
        row["bits"].should eq(5)
        row["kind"].should eq("b")
        row["nothing"].should be_nil
      ensure
        conn.close
      end
    end

    it "lets the server parse placeholders (literals, comments)" do
      conn = MySQLSpec.connect(url)
      begin
        conn.query("SELECT '?' AS q, ? AS v /* ? */", [1] of MySQLSpec::Value).rows.should eq([["?", 1]])
        conn.query("SELECT ? AS a, ? AS b", ["it's", nil] of MySQLSpec::Value).rows.should eq([["it's", nil]])
      ensure
        conn.close
      end
    end

    it "keeps prepared statements in a per-connection LRU cache" do
      conn = MySQLSpec.connect(url, statement_cache_size: 2)
      begin
        prepares, closes = MySQLSpec.statement_counters(conn)
        conn.query("SELECT ? + 1", [1] of MySQLSpec::Value)
        conn.query("SELECT ? + 2", [1] of MySQLSpec::Value)
        conn.query("SELECT ? + 1", [1] of MySQLSpec::Value) # cache hit, now most recently used
        conn.query("SELECT ? + 3", [1] of MySQLSpec::Value) # evicts "SELECT ? + 2"
        conn.cached_statement_count.should eq(2)
        conn.query("SELECT ? + 1", [5] of MySQLSpec::Value).scalar.should eq(6)
        MySQLSpec.statement_counters(conn).should eq({prepares + 3, closes + 1})
      ensure
        conn.close
      end
    end

    it "closes statements right away with statement_cache_size=0" do
      conn = MySQLSpec.connect(url, statement_cache_size: 0)
      begin
        prepares, closes = MySQLSpec.statement_counters(conn)
        2.times { conn.query("SELECT ?", [1] of MySQLSpec::Value) }
        conn.cached_statement_count.should eq(0)
        MySQLSpec.statement_counters(conn).should eq({prepares + 2, closes + 2})
      ensure
        conn.close
      end
    end

    it "interpolates client side with prepared_statements=false" do
      conn = MySQLSpec.connect(url, prepared_statements: false)
      begin
        conn.prepared_statements?.should be_false
        prepares, _ = MySQLSpec.statement_counters(conn)
        conn.query("SELECT ? AS a, '?' AS b", ["it's"] of MySQLSpec::Value).rows.should eq([["it's", "?"]])
        MySQLSpec.statement_counters(conn)[0].should eq(prepares)
      ensure
        conn.close
      end
    end

    it "sees schema changes made after a statement was prepared" do
      conn = MySQLSpec.connect(url)
      begin
        conn.exec_script("CREATE TEMPORARY TABLE silth_reprepare (id INT PRIMARY KEY); INSERT INTO silth_reprepare VALUES (1)")
        sql = "SELECT * FROM silth_reprepare WHERE id = ?"
        conn.query(sql, [1] of MySQLSpec::Value).columns.should eq(["id"])
        conn.exec_script("ALTER TABLE silth_reprepare ADD COLUMN extra INT NOT NULL DEFAULT 7")
        conn.query(sql, [1] of MySQLSpec::Value).first?.should eq({"id" => 1, "extra" => 7})
      ensure
        conn.close
      end
    end

    it "falls back to interpolation for statements the server cannot prepare" do
      conn = MySQLSpec.connect(url)
      begin
        conn.exec_script("CREATE TEMPORARY TABLE silth_handler (id INT PRIMARY KEY); INSERT INTO silth_handler VALUES (1), (2)")
        conn.exec_script("HANDLER silth_handler OPEN")
        conn.query("HANDLER silth_handler READ `PRIMARY` = (?)", [2] of MySQLSpec::Value).rows.should eq([[2]])
        conn.exec_script("HANDLER silth_handler CLOSE")
      ensure
        conn.close
      end
    end

    it "checks the parameter count and maps server errors" do
      conn = MySQLSpec.connect(url)
      begin
        expect_raises(Silth::DB::Error, /expects 2 parameter/) do
          conn.query("SELECT ?, ?", [1] of MySQLSpec::Value)
        end
        conn.exec_script("CREATE TEMPORARY TABLE silth_unique (email VARCHAR(50) UNIQUE)")
        conn.query("INSERT INTO silth_unique VALUES (?)", ["a@b.c"] of MySQLSpec::Value)
        expect_raises(Silth::DB::UniqueViolation) do
          conn.query("INSERT INTO silth_unique VALUES (?)", ["a@b.c"] of MySQLSpec::Value)
        end
        conn.query("SELECT COUNT(*) FROM silth_unique WHERE email = ?", ["a@b.c"] of MySQLSpec::Value).scalar.should eq(1)
      ensure
        conn.close
      end
    end
  end
end

if (admin_url = ENV["SILTH_TEST_MYSQL_ADMIN_URL"]?) && MySQLSpec.url
  describe "MySQL authentication" do
    it "authenticates caching_sha2_password users without TLS (RSA key exchange)" do
      admin = MySQLSpec.connect(admin_url)
      dir = File.tempname("silth-mysql-key", nil)
      begin
        plugin = admin.query("SELECT plugin_status FROM information_schema.plugins WHERE plugin_name = 'caching_sha2_password'", [] of MySQLSpec::Value).scalar
        pending!("caching_sha2_password is not available on this server") unless plugin == "ACTIVE"
        admin.exec_script("DROP USER IF EXISTS 'silth_rsa'@'%'; CREATE USER 'silth_rsa'@'%' IDENTIFIED WITH caching_sha2_password BY 'Rsa-p4ss!'")

        # A new account has no cache entry: full authentication, password sent RSA-encrypted.
        conn = MySQLSpec.connect(admin_url, user: "silth_rsa", password: "Rsa-p4ss!")
        conn.query("SELECT CURRENT_USER()", [] of MySQLSpec::Value).scalar.should eq("silth_rsa@%")
        conn.close
        # Now cached: fast authentication (scramble only).
        MySQLSpec.connect(admin_url, user: "silth_rsa", password: "Rsa-p4ss!").close

        # Pinned public key: no key request on the wire.
        key = admin.query("SHOW STATUS LIKE 'Caching_sha2_password_rsa_public_key'", [] of MySQLSpec::Value).rows.first[1].to_s
        Dir.mkdir(dir)
        File.write(File.join(dir, "public_key.pem"), key)
        admin.exec_script("FLUSH PRIVILEGES") # empties the authentication cache
        MySQLSpec.connect(admin_url, user: "silth_rsa", password: "Rsa-p4ss!", server_public_key: File.join(dir, "public_key.pem")).close

        admin.exec_script("FLUSH PRIVILEGES")
        expect_raises(Silth::DB::ConnectionError, /Access denied/) do
          MySQLSpec.connect(admin_url, user: "silth_rsa", password: "wrong")
        end
        expect_raises(Silth::DB::ConnectionError, /Cannot read MySQL server public key/) do
          MySQLSpec.connect(admin_url, user: "silth_rsa", password: "Rsa-p4ss!", server_public_key: File.join(dir, "missing.pem"))
        end
      ensure
        admin.exec_script("DROP USER IF EXISTS 'silth_rsa'@'%'") rescue nil
        admin.close
        FileUtils.rm_rf(dir)
      end
    end

    it "authenticates sha256_password users without TLS" do
      admin = MySQLSpec.connect(admin_url)
      begin
        plugin = admin.query("SELECT plugin_status FROM information_schema.plugins WHERE plugin_name = 'sha256_password'", [] of MySQLSpec::Value).scalar
        pending!("sha256_password is not available on this server") unless plugin == "ACTIVE"
        admin.exec_script("DROP USER IF EXISTS 'silth_sha256'@'%'; CREATE USER 'silth_sha256'@'%' IDENTIFIED WITH sha256_password BY 'Sha-p4ss!'")
        conn = MySQLSpec.connect(admin_url, user: "silth_sha256", password: "Sha-p4ss!")
        conn.query("SELECT CURRENT_USER()", [] of MySQLSpec::Value).scalar.should eq("silth_sha256@%")
        conn.close
      ensure
        admin.exec_script("DROP USER IF EXISTS 'silth_sha256'@'%'") rescue nil
        admin.close
      end
    end
  end
end
