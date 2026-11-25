module Silth
  # Cache, session and log drivers on PostgreSQL UNLOGGED tables: no write-ahead
  # log, so writes cost a fraction of a regular table's, and PostgreSQL empties
  # them after a crash (not after a clean restart). A good fit for data that can
  # be rebuilt, on a database you already run, without Redis.
  #
  # ```yaml
  # # config/cache.yml
  # default: postgres
  # stores:
  #   postgres: { connection: primary }
  #
  # # config/session.yml
  # driver: postgres
  #
  # # config/logging.yml
  # postgres: { connection: primary, level: info, retention_days: 14 }
  # ```
  module Unlogged
    # The database of *connection*, checked to be PostgreSQL.
    def self.database(connection : String?, what : String) : DB::Database
      db = DB.connection(connection)
      unless db.dialect.name == "postgres"
        raise ConfigError.new("The #{what} needs a PostgreSQL connection (#{db.name} is #{db.dialect.name})")
      end
      db
    end
  end

  # `driver: postgres` cache store (UNLOGGED table `silth_unlogged_cache`).
  # Every operation is a single statement, `add` and `increment` included.
  class PostgresCache < CacheStore
    DEFAULT_TABLE = "silth_unlogged_cache"

    @ready = false
    @writes = 0

    def initialize(name : String = "postgres", @connection : String? = nil, @table : String = DEFAULT_TABLE)
      super(name)
    end

    private def db : DB::Database
      database = Unlogged.database(@connection, "postgres cache store")
      unless @ready
        DB::Schema.new(database).ensure_table(@table, unlogged: true) do |t|
          t.text :key, null: false
          t.text :value, null: false
          t.timestamp :expires_at
          t.primary_key [:key]
        end
        @ready = true
      end
      database
    end

    private def q : String
      DB::Dialect::Postgres.new.quote(@table)
    end

    def read(key : String) : String?
      db.scalar("SELECT value FROM #{q} WHERE key = ? AND (expires_at IS NULL OR expires_at > now())", [key] of DB::Value).try(&.to_s)
    end

    def write(key : String, value : String, ttl : Time::Span?) : Nil
      db.query("INSERT INTO #{q} (key, value, expires_at) VALUES (?, ?, ?) ON CONFLICT (key) DO UPDATE " \
               "SET value = EXCLUDED.value, expires_at = EXCLUDED.expires_at", [key, value, expires(ttl)] of DB::Value)
      prune
    end

    # Sets the key unless a live value exists (an expired one is replaced).
    def add(key : String, value : String, ttl : Time::Span?) : Bool
      result = db.query("INSERT INTO #{q} AS c (key, value, expires_at) VALUES (?, ?, ?) ON CONFLICT (key) DO UPDATE " \
                        "SET value = EXCLUDED.value, expires_at = EXCLUDED.expires_at " \
                        "WHERE c.expires_at IS NOT NULL AND c.expires_at <= now() RETURNING key", [key, value, expires(ttl)] of DB::Value)
      !result.empty?
    end

    def delete(key : String) : Bool
      db.exec("DELETE FROM #{q} WHERE key = ?", [key] of DB::Value) > 0
    end

    # Atomic counter; *ttl* applies when the key is created (or had expired).
    def increment(key : String, by : Int64 = 1, ttl : Time::Span? = nil) : Int64
      sql = "INSERT INTO #{q} AS c (key, value, expires_at) VALUES (?, ?, ?) ON CONFLICT (key) DO UPDATE SET " \
            "value = (CASE WHEN c.expires_at IS NOT NULL AND c.expires_at <= now() THEN 0 ELSE c.value::bigint END + ?)::text, " \
            "expires_at = CASE WHEN c.expires_at IS NOT NULL AND c.expires_at <= now() THEN EXCLUDED.expires_at ELSE c.expires_at END " \
            "RETURNING value"
      db.scalar(sql, [key, by.to_s, expires(ttl), by] of DB::Value).to_s.to_i64
    end

    def clear : Nil
      db.query("TRUNCATE #{q}")
    end

    private def expires(ttl : Time::Span?) : DB::Value
      ttl.try { |t| Time.utc + t }
    end

    # Expired rows are removed every 500 writes.
    private def prune : Nil
      return unless (@writes += 1) % 500 == 0
      db.query("DELETE FROM #{q} WHERE expires_at IS NOT NULL AND expires_at <= now()")
    end
  end

  # `driver: postgres` session store: the cookie holds a signed id, the data lives
  # in the UNLOGGED table `silth_sessions` (a crash logs everybody out).
  class PostgresSessionStore
    include SessionStore

    TABLE = "silth_sessions"

    @ready = false
    @saves = 0

    def initialize(@cookie_name : String, @verifier : MessageVerifier, @options : CookieOptions, @ttl : Time::Span,
                   @connection : String? = nil)
    end

    private def db : DB::Database
      database = Unlogged.database(@connection, "postgres session store")
      unless @ready
        DB::Schema.new(database).ensure_table(TABLE, unlogged: true) do |t|
          t.string :id, null: false, limit: 64
          t.text :data, null: false
          t.timestamp :expires_at, null: false
          t.primary_key [:id]
        end
        @ready = true
      end
      database
    end

    def load(ctx : Context) : Session?
      cookie = ctx.request.cookies[@cookie_name]? || return nil
      id = @verifier.verify?(cookie.value) || return nil
      raw = db.scalar("SELECT data FROM #{TABLE} WHERE id = ? AND expires_at > now()", [id] of DB::Value)
      raw ? Session.new(id, Hash(String, String).from_json(raw.to_s)) : Session.new(id)
    rescue ex : JSON::ParseException
      nil
    end

    def save(ctx : Context, session : Session) : Nil
      database = db
      session.previous_id.try { |old| database.query("DELETE FROM #{TABLE} WHERE id = ?", [old] of DB::Value) }
      if session.destroyed? && session.data.empty?
        database.query("DELETE FROM #{TABLE} WHERE id = ?", [session.id] of DB::Value)
        ctx.response.cookies << @options.build(@cookie_name, "", expires: Time.unix(0))
        return
      end
      database.query("INSERT INTO #{TABLE} (id, data, expires_at) VALUES (?, ?, ?) ON CONFLICT (id) DO UPDATE " \
                     "SET data = EXCLUDED.data, expires_at = EXCLUDED.expires_at",
        [session.id, session.data.to_json, Time.utc + @ttl] of DB::Value)
      database.query("DELETE FROM #{TABLE} WHERE expires_at <= now()") if (@saves += 1) % 200 == 0
      ctx.response.cookies << @options.build(@cookie_name, @verifier.generate(session.id))
    end
  end

  module Logging
    # Log backend writing to the UNLOGGED table `silth_logs`, in batches from a
    # background fiber (one INSERT per second or per 200 entries). Entries from
    # the database layer are skipped (they would log themselves forever).
    #
    # ```
    # Silth::DB.query("SELECT level, source, message, data FROM silth_logs WHERE level = 'error' ORDER BY id DESC LIMIT 20")
    # ```
    class PostgresBackend < ::Log::Backend
      TABLE       = "silth_logs"
      BATCH_SIZE  =    200
      MAX_PENDING = 20_000

      alias Row = {Time, String, String, String, String, String?}

      @buffer = [] of Row
      @mutex = Mutex.new
      @wake = ::Channel(Nil).new(1)
      @ready = false
      @flushes = 0
      @dropped = 0

      def initialize(@connection : String? = nil, @retention : Time::Span = 14.days, @interval : Time::Span = 1.second)
        super(:direct)
        spawn(name: "silth-log-postgres") { run }
      end

      # Buffers the entry; only the background fiber writes, so a log line never
      # joins (and never rolls back with) the caller's transaction.
      def write(entry : ::Log::Entry) : Nil
        return if entry.source.starts_with?("silth.db") || Fiber.current.name == "silth-log-postgres"
        fields = {} of String => String
        entry.context.each { |k, v| fields[k.to_s] = v.to_s }
        entry.data.each { |k, v| fields[k.to_s] = v.to_s }
        row = {entry.timestamp, entry.severity.label.downcase, entry.source, entry.message, fields.to_json,
               entry.exception.try(&.inspect_with_backtrace)}
        full = @mutex.synchronize do
          if @buffer.size >= MAX_PENDING # the database is unreachable: keep the newest entries
            @buffer.shift
            @dropped += 1
          end
          @buffer << row
          @buffer.size >= BATCH_SIZE
        end
        if full
          select
          when @wake.send(nil)
          else # a flush is already pending
          end
        end
      end

      # Writes the buffered entries now.
      def flush : Nil
        rows = @mutex.synchronize { @buffer.dup.tap { @buffer.clear } }
        return if rows.empty?
        rows.each_slice(BATCH_SIZE) { |slice| insert(slice) }
        if (@flushes += 1) % 600 == 1
          database.query("DELETE FROM #{TABLE} WHERE created_at < ?", [Time.utc - @retention] of DB::Value)
        end
      rescue ex
        STDERR.puts "silth: could not write log entries to #{TABLE}: #{ex.message}"
      end

      def close : Nil
        flush
      end

      # Entries dropped because the buffer was full.
      def dropped : Int32
        @mutex.synchronize { @dropped }
      end

      private def run : Nil
        loop do
          select
          when @wake.receive
          when timeout(@interval)
          end
          flush
        end
      end

      private def insert(rows : Array(Row)) : Nil
        args = [] of DB::Value
        values = rows.map do |(at, level, source, message, data, exception)|
          args.concat([at, level, source, message, data, exception] of DB::Value)
          "(?, ?, ?, ?, ?::jsonb, ?)"
        end
        database.query("INSERT INTO #{TABLE} (created_at, level, source, message, data, exception) VALUES #{values.join(", ")}", args)
      end

      private def database : DB::Database
        db = Unlogged.database(@connection, "postgres log backend")
        unless @ready
          DB::Schema.new(db).ensure_table(TABLE, unlogged: true) do |t|
            t.id
            t.timestamp :created_at, null: false, index: true
            t.string :level, null: false, limit: 10
            t.string :source, null: false
            t.text :message, null: false
            t.json :data
            t.text :exception
          end
          @ready = true
        end
        db
      end
    end
  end
end
