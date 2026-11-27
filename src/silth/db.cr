require "json"
require "uri"

class Fiber
  # :nodoc: connections pinned by open transactions, per database name.
  property silth_db_tx : Hash(String, Silth::DB::Connection)?
  # :nodoc: databases written during the current request or job: their reads stay on the primary.
  property silth_db_written : Set(String)?
  # :nodoc: depth of `DB.on_primary` blocks.
  property silth_db_on_primary = 0
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
  #     replicas: [postgres://replica-1/app, postgres://replica-2/app]   # optional, see `Replica`
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
                  ::Silth::Decimal | ::Silth::Date |
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

    # Fixed-size connection pool safe to use from many fibers, and fair to them.
    #
    # Under contention (more fibers than connections), a released connection
    # goes back to the idle list and wakes the longest waiting fiber; a fiber
    # arriving at that moment may take it first, which keeps throughput high.
    # Once the oldest waiter has waited more than `STARVATION_THRESHOLD`, the
    # pool switches to first come, first served: released connections are
    # handed directly to the waiters in order, and newcomers queue behind them
    # (the policy of Go's `sync.Mutex`). This bounds tail latency.
    class Pool
      # How long a waiting fiber may be overtaken before connections are handed over in order.
      STARVATION_THRESHOLD = 1.millisecond

      # :nodoc: a fiber waiting for a connection. The channel receives a
      # connection (handed over) or nil (try again).
      class Waiter
        getter channel = ::Channel(Connection?).new(1)
        getter since : Time::Instant

        def initialize(@since = Time.instant)
        end
      end

      getter max_size : Int32
      getter total = 0
      @idle = Deque(Connection).new
      @waiters = Deque(Waiter).new
      @mutex = Mutex.new

      def initialize(@max_size : Int32, @timeout : Time::Span, &@factory : -> Connection)
      end

      def checkout : Connection
        deadline = Time.instant + @timeout
        waiter : Waiter? = nil
        loop do
          create = false
          @mutex.synchronize do
            # A fiber already waiting goes before newcomers once someone starves.
            if waiter || !starving?
              while conn = @idle.shift?
                return conn unless conn.closed?
                @total -= 1
              end
            end
            if @total < @max_size
              @total += 1
              create = true
            else
              # A woken waiter that lost the race keeps its place at the front.
              if w = waiter
                @waiters.unshift(w)
              else
                waiter = Waiter.new
                @waiters.push(waiter.not_nil!)
              end
            end
          end
          if create
            begin
              return @factory.call
            rescue ex
              @mutex.synchronize { @total -= 1 }
              wake_next
              raise ex
            end
          end
          current = waiter.not_nil!
          remaining = deadline - Time.instant
          if remaining > Time::Span.zero
            select
            when handed = current.channel.receive
              return handed if handed
              next
            when timeout(remaining)
            end
          end
          # Timed out: leave the queue, unless a connection was handed over meanwhile.
          handed = @mutex.synchronize do
            if @waiters.delete(current)
              nil
            else
              select
              when c = current.channel.receive then c
              else                                  nil
              end
            end
          end
          return handed if handed
          raise PoolTimeout.new("Timed out waiting for a database connection (pool size #{@max_size})")
        end
      end

      def release(conn : Connection) : Nil
        @mutex.synchronize do
          if conn.closed? || conn.broken?
            conn.close rescue nil
            @total -= 1
            # Room for a new connection: let the oldest waiter open it.
            @waiters.shift?.try &.channel.send(nil)
          elsif waiter = @waiters.first?
            @waiters.shift
            if Time.instant - waiter.since > STARVATION_THRESHOLD
              waiter.channel.send(conn) # hand over: no one can overtake it
            else
              @idle.push(conn)
              waiter.channel.send(nil) # wake it; a running fiber may still be faster
            end
          else
            @idle.push(conn)
          end
        end
      end

      def close : Nil
        @mutex.synchronize do
          @idle.each { |c| c.close rescue nil }
          @idle.clear
          @total = 0
          @waiters.each &.channel.send(nil)
          @waiters.clear
        end
      end

      def idle_count : Int32
        @mutex.synchronize { @idle.size }
      end

      # Fibers waiting for a connection.
      def waiting : Int32
        @mutex.synchronize { @waiters.size }
      end

      # True when the oldest waiting fiber has waited too long (called under the mutex).
      private def starving? : Bool
        (w = @waiters.first?) ? Time.instant - w.since > STARVATION_THRESHOLD : false
      end

      private def wake_next : Nil
        @mutex.synchronize { @waiters.shift?.try &.channel.send(nil) }
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
      # Read replicas: reads outside transactions go to one of them (see `Replica`).
      getter replicas = [] of Replica
      # How long the requests of a client keep reading from the primary after one
      # of them wrote (a cookie): a redirect after a form then sees its own write.
      property sticky_for : Time::Span = 2.seconds
      @next_replica = Atomic(UInt32).new(0_u32)

      def initialize(@name : String, url : String, pool_size : Int32 = 10, @timeout : Time::Span = 5.seconds, replicas : Array(String) = [] of String)
        @url = DB.parse_url(url)
        @dialect = Dialect.for(@url.scheme || "")
        size = @dialect.name == "sqlite" && memory? ? 1 : pool_size
        @pool = Pool.new(size, timeout) { DB.open_connection(@url) }
        replicas.each { |replica_url| add_replica(replica_url, pool_size) }
      end

      # Adds a read replica (same kind of database as the primary).
      def add_replica(url : String, pool_size : Int32 = @pool.max_size) : Replica
        replica = Replica.new(@replicas.size + 1, DB.parse_url(url), pool_size, @timeout)
        unless Dialect.for(replica.url.scheme || "").name == @dialect.name
          raise ConnectionError.new("Replica #{replica.url.scheme}:// of '#{@name}' is not a #{@dialect.name} database")
        end
        @replicas << replica
        replica
      end

      def memory? : Bool
        (@url.host || "").includes?(":memory:") || (@url.path || "").includes?(":memory:")
      end

      # Runs a statement and returns its rows. Use `?` placeholders on every database.
      #
      # With replicas, a read (`SELECT`, `WITH`, `SHOW`, `EXPLAIN` without a locking
      # clause) outside a transaction goes to a replica, unless the current request
      # or job already wrote to this database (see `Replica`).
      def query(sql : String, args : Enumerable = [] of Value) : ResultSet
        values = DB.values(args)
        prepared = @dialect.prepare_sql(sql)
        replica = route(sql)
        attempts = 0
        loop do
          attempts += 1
          started = Time.instant
          begin
            result = replica ? replica.with_connection { |conn| conn.query(prepared, values) } : with_connection { |conn| conn.query(prepared, values) }
            duration = Time.instant - started
            Instrument.query(sql, values, duration, replica ? "#{@name} (replica #{replica.index})" : @name, result.rows.empty? ? result.rows_affected.to_i32 : result.rows.size)
            Log.warn { "Slow query (#{duration.total_milliseconds.round(1)}ms): #{sql}" } if duration > @slow_query_threshold
            return result
          rescue ex : IO::Error | ConnectionError
            if failed = replica # an unreachable replica: rest it, read from the primary
              failed.rest
              replica = nil
              Log.warn { "Replica #{failed.index} of '#{@name}' unreachable (#{ex.message}); reading from the primary" }
              attempts -= 1
              next
            end
            raise ex if attempts > 1 || in_transaction?
            Log.warn { "Database connection lost (#{ex.message}); retrying once" }
          end
        end
      end

      # The replica a statement runs on, or nil for the primary. Writes mark the
      # current request or job: its later reads stay on the primary.
      private def route(sql : String) : Replica?
        return nil if @replicas.empty? || in_transaction?
        unless DB.read_statement?(sql)
          DB.mark_written(@name)
          return nil
        end
        return nil if DB.on_primary? || DB.written?(@name)
        @replicas.size.times do
          replica = @replicas[@next_replica.add(1_u32) % @replicas.size]
          return replica if replica.available?
        end
        nil
      end

      # True when reads can go to a replica.
      def replicated? : Bool
        !@replicas.empty?
      end

      def exec(sql : String, args : Enumerable = [] of Value) : Int64
        query(sql, args).rows_affected
      end

      def scalar(sql : String, args : Enumerable = [] of Value) : Value
        query(sql, args).scalar
      end

      # Executes several statements separated by `;` (no parameters), on the primary.
      def exec_script(sql : String) : Nil
        DB.mark_written(@name) if replicated?
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
      #
      # The transaction commits when the block finishes, including with `return`
      # or `break`, and rolls back when it raises (the exception is re-raised).
      def transaction(&)
        txs = (Fiber.current.silth_db_tx ||= {} of String => Connection)
        if conn = txs[@name]?
          return savepoint(conn) { yield }
        end
        DB.mark_written(@name) if replicated?
        conn = @pool.checkout
        txs[@name] = conn
        done = false
        begin
          conn.query(@dialect.begin_sql, [] of Value)
          result = yield
          done = true
          commit(conn)
          result
        rescue ex
          unless done
            done = true
            conn.query("ROLLBACK", [] of Value) unless conn.closed? rescue nil
          end
          raise ex
        ensure
          commit(conn) unless done # `return` or `break` from the block
          txs.delete(@name)
          after_commit_callbacks.clear
          @pool.release(conn)
        end
      end

      private def commit(conn : Connection) : Nil
        conn.query("COMMIT", [] of Value)
        after_commit_callbacks.each &.call
      end

      private def savepoint(conn : Connection, &)
        depth = (@savepoint_depth[conn.object_id]? || 0) + 1
        @savepoint_depth[conn.object_id] = depth
        sp = "silth_sp_#{depth}"
        conn.query("SAVEPOINT #{sp}", [] of Value)
        done = false
        begin
          result = yield
          done = true
          conn.query("RELEASE SAVEPOINT #{sp}", [] of Value)
          result
        rescue ex
          unless done
            done = true
            # Keep the original error: the savepoint may be gone already (on MySQL,
            # DDL commits the transaction and its savepoints).
            conn.query("ROLLBACK TO SAVEPOINT #{sp}", [] of Value) unless conn.closed? rescue nil
          end
          raise ex
        ensure
          conn.query("RELEASE SAVEPOINT #{sp}", [] of Value) unless done # `return` or `break` from the block
          @savepoint_depth[conn.object_id] = depth - 1
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
        @replicas.each &.close
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
        key = "database.connections.#{name}"
        db = register(name, url, config.int("#{key}.pool", 10), config.int("#{key}.timeout", 5).seconds,
          replicas: config.array("#{key}.replicas").reject(&.empty?))
        db.sticky_for = config.int("#{key}.sticky_for", 2).seconds
      end
      if @@databases.empty? && (url = ENV["DATABASE_URL"]? || config.string?("database.url"))
        register(@@default, url, config.int("database.pool", 10))
      end
    end

    def self.register(name : String, url : String, pool : Int32 = 10, timeout : Time::Span = 5.seconds, replicas : Array(String) = [] of String) : Database
      @@databases[name]?.try &.close
      @@databases[name] = Database.new(name, url, pool, timeout, replicas)
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
      when BigDecimal  then ::Silth::Decimal.new(v)
      when BigInt      then ::Silth::Decimal.new(v)
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
