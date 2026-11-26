module Silth::DB
  # A read replica of a `Database`: its own pool, rested for a while when it
  # cannot be reached.
  #
  # ```yaml
  # # config/database.yml
  # connections:
  #   primary:
  #     url: postgres://app@primary/app
  #     replicas:
  #       - postgres://app@replica-1/app
  #       - postgres://app@replica-2/app
  #     sticky_for: 2          # seconds a client keeps reading from the primary after a write
  # ```
  #
  # Routing, per statement:
  #
  # - reads (`SELECT`, `WITH`, `SHOW`, `EXPLAIN`, without `FOR UPDATE`/`FOR SHARE`)
  #   go to the replicas in turn;
  # - writes, transactions and `exec_script` go to the primary;
  # - once a request or a job wrote to the database, its reads stay on the primary
  #   (it sees its own writes), and so do the next requests of the same client for
  #   `sticky_for` seconds (a cookie), so a redirect after a form reads fresh data;
  # - `DB.on_primary { … }` forces the primary for a block.
  class Replica
    Log = ::Log.for("silth.db")

    # How long an unreachable replica is skipped.
    REST = 10.seconds

    getter index : Int32
    getter url : URI
    getter pool : Pool
    @resting_until : Time::Instant? = nil

    def initialize(@index : Int32, @url : URI, pool_size : Int32, timeout : Time::Span)
      @pool = Pool.new(pool_size, timeout) { DB.open_connection(@url) }
    end

    def available? : Bool
      if resting = @resting_until
        return false if Time.instant < resting
        @resting_until = nil
      end
      true
    end

    # Skips this replica for `REST`.
    def rest : Nil
      @resting_until = Time.instant + REST
    end

    def with_connection(&)
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

    def close : Nil
      @pool.close
    end
  end

  # Cookie keeping a client on the primary for `Database#sticky_for` after a write.
  STICKY_COOKIE = "silth_db_primary"

  READ_STATEMENT = /\A[\s(]*(?:SELECT|WITH|SHOW|EXPLAIN|DESCRIBE|DESC|VALUES|TABLE)\b/i
  LOCKING_CLAUSE = /\bFOR\s+(?:NO\s+KEY\s+)?UPDATE\b|\bFOR\s+(?:KEY\s+)?SHARE\b|\bLOCK\s+IN\s+SHARE\s+MODE\b/i
  WRITE_KEYWORD  = /\b(?:INSERT|UPDATE|DELETE|MERGE|CREATE|ALTER|DROP|TRUNCATE|CALL|LOCK)\b/i
  SIDE_EFFECTS   = /\b(?:nextval|setval|pg_advisory_\w*lock\w*|pg_notify|get_lock|release_lock|last_insert_id)\s*\(/i

  # True for statements a replica can answer: reads without locks, sequences,
  # advisory locks or data-modifying CTEs.
  #
  # ```
  # DB.read_statement?("SELECT * FROM posts")                # => true
  # DB.read_statement?("SELECT * FROM jobs FOR UPDATE")      # => false
  # DB.read_statement?("WITH n AS (DELETE FROM t) SELECT 1") # => false
  # ```
  def self.read_statement?(sql : String) : Bool
    return false unless sql.matches?(READ_STATEMENT)
    return false if sql.matches?(LOCKING_CLAUSE) || sql.matches?(SIDE_EFFECTS)
    !(sql.lstrip.starts_with?(/with/i) && sql.matches?(WRITE_KEYWORD))
  end

  # Runs the block with every read on the primary (fresh data, no replica lag).
  #
  # ```
  # order = DB.on_primary { Order.find(id) }
  # ```
  def self.on_primary(&)
    fiber = Fiber.current
    fiber.silth_db_on_primary += 1
    begin
      yield
    ensure
      fiber.silth_db_on_primary -= 1
    end
  end

  def self.on_primary? : Bool
    Fiber.current.silth_db_on_primary > 0
  end

  # Records that the current request or job wrote to *name*.
  def self.mark_written(name : String) : Nil
    (Fiber.current.silth_db_written ||= Set(String).new) << name
  end

  def self.written?(name : String) : Bool
    !!Fiber.current.silth_db_written.try(&.includes?(name))
  end

  # Starts a unit of work (a request, a job): reads may go to replicas again.
  def self.reset_stickiness : Nil
    Fiber.current.silth_db_written = nil
  end

  # Called by the app for each request: restores the databases a recent request
  # of this client wrote to (cookie), and sets the cookie when this one writes.
  def self.begin_request(ctx : Context) : Nil
    reset_stickiness
    replicated = @@databases.values.select(&.replicated?)
    return if replicated.empty?
    ctx.cookies[STICKY_COOKIE]?.try do |cookie|
      cookie.value.split(',').each { |name| mark_written(name) if @@databases[name]?.try(&.replicated?) }
    end
    ctx.before_send do
      written = replicated.select { |db| written?(db.name) && db.sticky_for > Time::Span.zero }
      next if written.empty?
      ctx.set_cookie(STICKY_COOKIE, written.map(&.name).join(','), max_age: written.max_of(&.sticky_for))
    end
  end
end
