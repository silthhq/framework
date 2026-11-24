require "json"
require "uri"

class Fiber
  # :nodoc: connections pinned by open transactions, per database name.
  property silth_db_tx : Hash(String, Silth::DB::Connection)?
end

module Silth
  # Database access layer: connection pools, dialects and home-made drivers for
  # PostgreSQL (wire protocol v3), MySQL/MariaDB (protocol 4.1) and SQLite (libsqlite3).
  #
  # ```yaml
  # # config/database.yml
  # default: primary
  # connections:
  #   primary:
  #     url: ${DATABASE_URL:-sqlite3://./db/development.sqlite3}
  #     pool: 10
  #   analytics:
  #     url: postgres://localhost/analytics
  # ```
  #
  # ```
  # Silth::DB.query("SELECT * FROM users WHERE id = ?", [1])
  # Silth::DB.table("users").where(active: true).count
  # Silth::DB.transaction { ... }
  # ```
  module DB
    alias Value = Nil | Bool | Int32 | Int64 | Float32 | Float64 | String | Bytes | Time | JSON::Any |
                  Array(String) | Array(Int32) | Array(Int64) | Array(Float32) | Array(Float64)
    alias Row = Hash(String, Value)

    class Error < Silth::Error; end

    class ConnectionError < Error; end

    class PoolTimeout < Error; end

    class Unsupported < Error; end

    # Raised for errors reported by the database server.
    class QueryError < Error
      getter code : String
      getter sql : String

      def initialize(message : String, @code : String = "", @sql : String = "")
        super(message)
      end
    end

    class UniqueViolation < QueryError; end

    class ForeignKeyViolation < QueryError; end

    class NotNullViolation < QueryError; end

    class SerializationFailure < QueryError; end

    # Result of a statement (rows are materialized).
    class ResultSet
      getter columns : Array(String)
      getter rows : Array(Array(Value))
      property rows_affected : Int64 = 0
      property last_insert_id : Int64? = nil

      def initialize(@columns = [] of String, @rows = [] of Array(Value))
      end

      def size : Int32
        @rows.size
      end

      def empty? : Bool
        @rows.empty?
      end

      def to_hashes : Array(Row)
        @rows.map { |r| to_hash(r) }
      end

      def to_hash(row : Array(Value)) : Row
        h = Row.new
        @columns.each_with_index { |c, i| h[c] = row[i]? }
        h
      end

      def first? : Row?
        @rows.first?.try { |r| to_hash(r) }
      end

      def scalar : Value
        @rows.first?.try(&.first?)
      end

      def each(& : Row ->)
        @rows.each { |r| yield to_hash(r) }
      end
    end

    # A physical connection implemented by a driver.
    abstract class Connection
      abstract def query(sql : String, args : Array(Value)) : ResultSet
      abstract def exec_script(sql : String) : Nil
      abstract def close : Nil
      abstract def closed? : Bool
      abstract def dialect : Dialect
      property? broken = false
    end

    # Fixed-size connection pool safe to use from many fibers.
    class Pool
      getter max_size : Int32
      getter total = 0
      @idle = Deque(Connection).new
      @mutex = Mutex.new
      @available : ::Channel(Nil)

      def initialize(@max_size : Int32, @timeout : Time::Span, &@factory : -> Connection)
        @available = ::Channel(Nil).new(@max_size)
      end

      def checkout : Connection
        deadline = Time.instant + @timeout
        loop do
          create = false
          @mutex.synchronize do
            while conn = @idle.shift?
              return conn unless conn.closed?
              @total -= 1
            end
            if @total < @max_size
              @total += 1
              create = true
            end
          end
          if create
            begin
              return @factory.call
            rescue ex
              @mutex.synchronize { @total -= 1 }
              raise ex
            end
          end
          remaining = deadline - Time.instant
          raise PoolTimeout.new("Timed out waiting for a database connection (pool size #{@max_size})") if remaining <= Time::Span.zero
          select
          when @available.receive
          when timeout(remaining)
          end
        end
      end

      def release(conn : Connection) : Nil
        @mutex.synchronize do
          if conn.closed? || conn.broken?
            conn.close rescue nil
            @total -= 1
          else
            @idle.push(conn)
          end
        end
        select
        when @available.send(nil)
        else
        end
      end

      def close : Nil
        @mutex.synchronize do
          @idle.each { |c| c.close rescue nil }
          @idle.clear
          @total = 0
        end
      end

      def idle_count : Int32
        @mutex.synchronize { @idle.size }
      end
    end

    # A named database: URL + dialect + pool.
    class Database
      Log = ::Log.for("silth.db")

      getter name : String
      getter url : URI
      getter dialect : Dialect
      getter pool : Pool
      property slow_query_threshold : Time::Span = 500.milliseconds

      def initialize(@name : String, url : String, pool_size : Int32 = 10, timeout : Time::Span = 5.seconds)
        @url = DB.parse_url(url)
        @dialect = Dialect.for(@url.scheme || "")
        size = @dialect.name == "sqlite" && memory? ? 1 : pool_size
        @pool = Pool.new(size, timeout) { DB.open_connection(@url) }
      end

      def memory? : Bool
        (@url.host || "").includes?(":memory:") || (@url.path || "").includes?(":memory:")
      end

      # Runs a statement and returns its rows. Use `?` placeholders on every database.
      def query(sql : String, args : Enumerable = [] of Value) : ResultSet
        values = DB.values(args)
        prepared = @dialect.prepare_sql(sql)
        attempts = 0
        loop do
          attempts += 1
          started = Time.instant
          begin
            result = with_connection { |conn| conn.query(prepared, values) }
            duration = Time.instant - started
            Instrument.query(sql, values, duration, @name, result.rows.empty? ? result.rows_affected.to_i32 : result.rows.size)
            Log.warn { "Slow query (#{duration.total_milliseconds.round(1)}ms): #{sql}" } if duration > @slow_query_threshold
            return result
          rescue ex : IO::Error | ConnectionError
            raise ex if attempts > 1 || in_transaction?
            Log.warn { "Database connection lost (#{ex.message}); retrying once" }
          end
        end
      end

      def exec(sql : String, args : Enumerable = [] of Value) : Int64
        query(sql, args).rows_affected
      end

      def scalar(sql : String, args : Enumerable = [] of Value) : Value
        query(sql, args).scalar
      end

      # Executes several statements separated by `;` (no parameters).
      def exec_script(sql : String) : Nil
        started = Time.instant
        with_connection { |conn| conn.exec_script(sql) }
        Instrument.query(sql, [] of Value, Time.instant - started, @name)
      end

      def in_transaction? : Bool
        !!Fiber.current.silth_db_tx.try(&.has_key?(@name))
      end

      def with_connection(&)
        if conn = Fiber.current.silth_db_tx.try(&.[@name]?)
          return yield conn
        end
        conn = @pool.checkout
        begin
          yield conn
        rescue ex : IO::Error
          conn.broken = true
          raise ex
        ensure
          @pool.release(conn)
        end
      end

      # Runs the block inside a transaction. Nested calls use savepoints.
      def transaction(&)
        txs = (Fiber.current.silth_db_tx ||= {} of String => Connection)
        if conn = txs[@name]?
          depth = (@savepoint_depth[conn.object_id]? || 0) + 1
          @savepoint_depth[conn.object_id] = depth
          sp = "silth_sp_#{depth}"
          conn.query("SAVEPOINT #{sp}", [] of Value)
          begin
            result = yield
            conn.query("RELEASE SAVEPOINT #{sp}", [] of Value)
            return result
          rescue ex
            conn.query("ROLLBACK TO SAVEPOINT #{sp}", [] of Value) unless conn.closed?
            raise ex
          ensure
            @savepoint_depth[conn.object_id] = depth - 1
          end
        end
        conn = @pool.checkout
        txs[@name] = conn
        begin
          conn.query(@dialect.begin_sql, [] of Value)
          result = yield
          conn.query("COMMIT", [] of Value)
          after_commit_callbacks.each &.call
          result
        rescue ex
          conn.query("ROLLBACK", [] of Value) unless conn.closed? rescue nil
          raise ex
        ensure
          txs.delete(@name)
          after_commit_callbacks.clear
          @pool.release(conn)
        end
      end

      @savepoint_depth = {} of UInt64 => Int32
      @after_commit = {} of UInt64 => Array(-> Nil)

      private def after_commit_callbacks : Array(-> Nil)
        @after_commit[Fiber.current.object_id] ||= [] of -> Nil
      end

      # Runs the block after the current transaction commits (immediately when none).
      def after_commit(&block : -> Nil) : Nil
        if in_transaction?
          after_commit_callbacks << block
        else
          block.call
        end
      end

      def table(name : String) : QueryBuilder
        QueryBuilder.new(name, self)
      end

      def tables : Array(String)
        query(@dialect.list_tables_sql).rows.map(&.first.to_s)
      end

      def table_exists?(table : String) : Bool
        tables.includes?(table)
      end

      def close : Nil
        @pool.close
      end
    end

    @@databases = {} of String => Database
    @@default = "primary"

    class_property default : String

    def self.boot : Nil
      config = Silth.config
      @@default = config.string("database.default", "primary")
      config.keys("database.connections").each do |name|
        url = config.string?("database.connections.#{name}.url") || next
        next if url.empty?
        register(name, url, config.int("database.connections.#{name}.pool", 10),
          config.int("database.connections.#{name}.timeout", 5).seconds)
      end
      if @@databases.empty? && (url = ENV["DATABASE_URL"]? || config.string?("database.url"))
        register(@@default, url, config.int("database.pool", 10))
      end
    end

    def self.register(name : String, url : String, pool : Int32 = 10, timeout : Time::Span = 5.seconds) : Database
      @@databases[name]?.try &.close
      @@databases[name] = Database.new(name, url, pool, timeout)
    end

    def self.[](name : String) : Database
      @@databases[name]? || raise Error.new("Unknown database connection '#{name}'. Configure it in config/database.yml")
    end

    def self.[]?(name : String) : Database?
      @@databases[name]?
    end

    def self.connection(name : String? = nil) : Database
      self[name || @@default]
    end

    def self.configured? : Bool
      !@@databases.empty?
    end

    def self.databases : Hash(String, Database)
      @@databases
    end

    def self.query(sql : String, args : Enumerable = [] of Value) : ResultSet
      connection.query(sql, args)
    end

    def self.exec(sql : String, args : Enumerable = [] of Value) : Int64
      connection.exec(sql, args)
    end

    def self.scalar(sql : String, args : Enumerable = [] of Value) : Value
      connection.scalar(sql, args)
    end

    def self.transaction(name : String? = nil, &)
      connection(name).transaction { yield }
    end

    def self.table(name : String, connection : String? = nil) : QueryBuilder
      self.connection(connection).table(name)
    end

    def self.parse_url(url : String) : URI
      if url.starts_with?("sqlite3:") || url.starts_with?("sqlite:")
        # sqlite3://./db/dev.sqlite3, sqlite3:///abs/path.db, sqlite3::memory:
        path = url.sub(/\Asqlite3?:(\/\/)?/, "")
        return URI.new(scheme: "sqlite3", path: path)
      end
      URI.parse(url)
    end

    def self.open_connection(url : URI) : Connection
      case url.scheme
      when "sqlite3", "sqlite"                 then SQLite::Connection.new(url)
      when "postgres", "postgresql", "pg"      then Postgres::Connection.new(url)
      when "mysql", "mariadb"                  then MySQL::Connection.new(url)
      else
        raise ConnectionError.new("Unsupported database scheme '#{url.scheme}' (use postgres://, mysql:// or sqlite3://)")
      end
    end

    # Converts any supported Crystal value into a `DB::Value`.
    def self.to_value(v) : Value
      case v
      when Value       then v
      when Int8, Int16, UInt8, UInt16 then v.to_i32
      when UInt32, UInt64 then v.to_i64
      when Enum        then v.value.to_i64
      when Symbol      then v.to_s
      when Char        then v.to_s
      when UUID        then v.to_s
      when Array       then JSON.parse(v.to_json)
      when Hash, NamedTuple then JSON.parse(v.to_json)
      else
        if v.responds_to?(:to_db_value)
          v.to_db_value
        else
          v.to_s
        end
      end
    end

    # Text representation used by drivers that send text parameters.
    def self.format_time(t : Time) : String
      t.to_utc.to_s("%Y-%m-%d %H:%M:%S.%6N")
    end

    # Parses database timestamps: `2026-11-24 12:00:00[.123456][+00[:00]]`, ISO 8601, dates.
    def self.parse_time(s : String) : Time
      str = s.strip
      if m = str.match(/\A(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?)?\s*(Z|[+-]\d{2}(?::?\d{2})?)?\z/)
        nanos = m[7]?.try { |f| f.ljust(9, '0').to_i } || 0
        time = Time.utc(m[1].to_i, m[2].to_i, m[3].to_i, m[4]?.try(&.to_i) || 0, m[5]?.try(&.to_i) || 0, m[6]?.try(&.to_i) || 0, nanosecond: nanos)
        if (off = m[8]?) && off != "Z"
          sign = off[0] == '-' ? -1 : 1
          digits = off[1..].delete(':')
          seconds = sign * (digits[0, 2].to_i * 3600 + (digits.size >= 4 ? digits[2, 2].to_i : 0) * 60)
          time -= seconds.seconds
        end
        time
      else
        Time.parse_iso8601(str)
      end
    end
  end
end
