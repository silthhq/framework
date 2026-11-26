module Silth
  # Background jobs.
  #
  # ```
  # class SendInvoiceJob < Silth::Job
  #   queue "mail"
  #   retries 5
  #
  #   getter invoice_id : Int64
  #
  #   def initialize(@invoice_id)
  #   end
  #
  #   def perform : Nil
  #     InvoiceMail.new(Invoice.find(invoice_id)).deliver
  #   end
  # end
  #
  # SendInvoiceJob.new(invoice.id).dispatch                    # asap
  # SendInvoiceJob.new(invoice.id).dispatch(delay: 10.minutes)
  # ```
  #
  # Unique and rate-limited jobs:
  #
  # ```
  # class SyncStockJob < Silth::Job
  #   unique for: 10.minutes      # dispatch is skipped (nil) while one with the same arguments waits or runs
  #   rate_limit 30, per: 1.minute # across every worker (through the cache store)
  # end
  # ```
  #
  # Run workers with `silth queue:work --queues=default,mail --concurrency=8`.
  abstract class Job
    include JSON::Serializable

    @[JSON::Field(ignore: true)]
    property attempts : Int32 = 0

    @[JSON::Field(ignore: true)]
    property job_id : String = ""

    # The batch this job belongs to (see `Silth::Batch`).
    @[JSON::Field(key: "__batch")]
    property batch_id : String? = nil

    # Set on the `on_success`/`on_failure`/`on_complete` job of a batch.
    @[JSON::Field(key: "__batch_callback")]
    property callback_batch_id : String? = nil

    abstract def perform : Nil

    # The batch this job belongs to, or reports on as a callback.
    def batch : Batch?
      (batch_id || callback_batch_id).try { |id| Batch.find(id) }
    end

    # Duplicate window of `unique` jobs (nil: not unique).
    def self.unique_for : Time::Span?
      nil
    end

    # `{limit, period}` shared by every job of this class (nil: unlimited).
    def self.rate_limit : {Int32, Time::Span}?
      nil
    end

    # Only one job with the same `unique_key` can wait or run at a time: `dispatch`
    # returns nil for duplicates. The lock is released when the job succeeds or
    # fails for good, or after *duration* at most (a crashed worker).
    macro unique(for duration = 1.hour)
      def self.unique_for : Time::Span?
        {{duration}}
      end
    end

    # At most *limit* jobs of this class start per *period*, across workers. Extra
    # jobs are put back until the next window (retries are not consumed).
    macro rate_limit(limit, per period = 1.second)
      def self.rate_limit : {Int32, Time::Span}?
        { {{limit}}, {{period}} }
      end
    end

    # What makes two jobs duplicates (default: the class and its arguments).
    def unique_key : String
      Crypto.sha256("#{self.class.name}:#{to_json}")[0, 40]
    end

    def self.queue_name : String
      "default"
    end

    def self.max_retries : Int32
      3
    end

    def self.timeout : Time::Span
      5.minutes
    end

    macro queue(name)
      def self.queue_name : String
        {{name.id.stringify}}
      end
    end

    macro retries(count)
      def self.max_retries : Int32
        {{count}}
      end
    end

    macro timeout(span)
      def self.timeout : Time::Span
        {{span}}
      end
    end

    # Delay before retry number `attempt` (exponential backoff with jitter).
    def backoff(attempt : Int32) : Time::Span
      ((2 ** attempt) * 5 + rand(5)).seconds
    end

    # Called when every retry failed.
    def failed(error : Exception) : Nil
    end

    def job_name : String
      self.class.name
    end

    # Queues the job; returns its id, or nil when a `unique` duplicate is pending.
    def dispatch(delay : Time::Span? = nil, queue : String? = nil) : String?
      Queue.push(self, queue || self.class.queue_name, delay)
    end

    # Dispatches after the current database transaction commits.
    def dispatch_after_commit(delay : Time::Span? = nil) : Nil
      if DB.configured?
        DB.connection.after_commit { dispatch(delay) }
      else
        dispatch(delay)
      end
    end

    def dispatch_now : Nil
      perform
    end

    # Rebuilds a job from its serialized payload.
    def self.deserialize(name : String, data : String) : Job
      {% begin %}
        case name
        {% for job in @type.all_subclasses.reject(&.abstract?) %}
          when {{job.name.stringify}} then {{job}}.from_json(data)
        {% end %}
        else
          raise Silth::Error.new("Unknown job class '#{name}'")
        end
      {% end %}
    end
  end

  module Queue
    Log = ::Log.for("silth.queue")

    record Envelope, id : String, job : String, queue : String, payload : String, attempts : Int32, available_at : Time do
      include JSON::Serializable
    end

    # Storage backend for jobs.
    abstract class Driver
      abstract def push(envelope : Envelope) : Nil
      abstract def pop(queues : Array(String)) : Envelope?
      abstract def ack(envelope : Envelope) : Nil
      # Puts a job back; *attempt* is false when it did not run (rate limit).
      abstract def release(envelope : Envelope, delay : Time::Span, attempt : Bool = true) : Nil
      abstract def size(queue : String) : Int64

      # False when jobs run inline (rate limits would loop).
      def deferred? : Bool
        true
      end

      def fail(envelope : Envelope, error : Exception) : Nil
        Queue.record_failure(envelope, error)
        ack(envelope)
      end
    end

    # Runs jobs inline (development / tests).
    class SyncDriver < Driver
      def push(envelope : Envelope) : Nil
        Queue.execute(envelope, self)
      end

      def pop(queues : Array(String)) : Envelope?
        nil
      end

      def ack(envelope : Envelope) : Nil
      end

      def release(envelope : Envelope, delay : Time::Span, attempt : Bool = true) : Nil
        Queue.execute(envelope.copy_with(attempts: envelope.attempts + (attempt ? 1 : 0)), self)
      end

      def deferred? : Bool
        false
      end

      def fail(envelope : Envelope, error : Exception) : Nil
        Log.error(exception: error) { "Job #{envelope.job} failed" }
      end

      def size(queue : String) : Int64
        0_i64
      end
    end

    # In-process queue processed by fibers (lost on restart).
    class MemoryDriver < Driver
      @jobs = [] of Envelope
      @mutex = Mutex.new

      def push(envelope : Envelope) : Nil
        @mutex.synchronize { @jobs << envelope }
      end

      def pop(queues : Array(String)) : Envelope?
        now = Time.utc
        @mutex.synchronize do
          idx = @jobs.index { |e| queues.includes?(e.queue) && e.available_at <= now }
          idx ? @jobs.delete_at(idx) : nil
        end
      end

      def ack(envelope : Envelope) : Nil
      end

      def release(envelope : Envelope, delay : Time::Span, attempt : Bool = true) : Nil
        push(envelope.copy_with(attempts: envelope.attempts + (attempt ? 1 : 0), available_at: Time.utc + delay))
      end

      def size(queue : String) : Int64
        @mutex.synchronize { @jobs.count { |e| e.queue == queue }.to_i64 }
      end
    end

    # Durable queue stored in `silth_jobs` (works on PostgreSQL, MySQL and SQLite).
    class DatabaseDriver < Driver
      TABLE = "silth_jobs"
      @ready = false

      def initialize(@connection : String? = nil)
      end

      def db : DB::Database
        prepare unless @ready
        DB.connection(@connection)
      end

      # Creates the queue tables now when they are missing.
      def prepare : Nil
        Queue.ensure_tables(DB.connection(@connection))
        @ready = true
      end

      def push(envelope : Envelope) : Nil
        db.table(TABLE).insert({
          "uid" => envelope.id.as(DB::Value), "job" => envelope.job.as(DB::Value), "queue" => envelope.queue.as(DB::Value),
          "payload" => envelope.payload.as(DB::Value), "attempts" => envelope.attempts.as(DB::Value),
          "available_at" => envelope.available_at.as(DB::Value), "created_at" => Time.utc.as(DB::Value),
        }, returning: nil)
      end

      # Claims a job atomically with a token (no long transaction held).
      def pop(queues : Array(String)) : Envelope?
        d = db
        token = Crypto.token(12)
        now = Time.utc
        stale = now - 15.minutes
        q = d.table(TABLE).where_in(:queue, queues).where(:available_at, "<=", now)
          .where_group { |g| g.where_null(:reserved_at).or_where(:reserved_at, "<", stale) }
          .order(id: :asc).limit(1)
        candidate = if d.dialect.supports_skip_locked?
                      d.transaction do
                        row = q.lock_for_update(skip_locked: true).first?
                        d.table(TABLE).where(id: row["id"]).update(reserved_at: now, token: token) if row
                        row
                      end
                    else
                      row = q.first?
                      if row
                        updated = d.table(TABLE).where(id: row["id"]).where_group { |g| g.where_null(:reserved_at).or_where(:reserved_at, "<", stale) }
                          .update(reserved_at: now, token: token)
                        row = nil if updated == 0
                      end
                      row
                    end
        row = candidate || return nil
        Envelope.new(row["uid"].to_s, row["job"].to_s, row["queue"].to_s, row["payload"].to_s, DB.as_i64(row["attempts"]).to_i32, now)
      end

      def ack(envelope : Envelope) : Nil
        db.table(TABLE).where(uid: envelope.id).delete
      end

      def release(envelope : Envelope, delay : Time::Span, attempt : Bool = true) : Nil
        db.table(TABLE).where(uid: envelope.id).update(reserved_at: nil, token: nil, attempts: envelope.attempts + (attempt ? 1 : 0), available_at: Time.utc + delay)
      end

      def size(queue : String) : Int64
        db.table(TABLE).where(queue: queue).count
      end
    end

    # Redis lists + a sorted set for delayed jobs.
    class RedisDriver < Driver
      def initialize(url : String, @prefix : String = "silth:queue:")
        @redis = Redis.new(url)
      end

      def push(envelope : Envelope) : Nil
        if envelope.available_at > Time.utc
          @redis.zadd("#{@prefix}delayed", envelope.available_at.to_unix, envelope.to_json)
        else
          @redis.lpush("#{@prefix}#{envelope.queue}", envelope.to_json)
        end
      end

      def pop(queues : Array(String)) : Envelope?
        migrate_delayed
        queues.each do |q|
          if raw = @redis.command("RPOP", "#{@prefix}#{q}").as?(String)
            return Envelope.from_json(raw)
          end
        end
        nil
      end

      private def migrate_delayed : Nil
        due = @redis.command("ZRANGEBYSCORE", "#{@prefix}delayed", "-inf", Time.utc.to_unix).as?(Array(Redis::Reply)) || return
        due.each do |raw|
          next unless raw.is_a?(String)
          if @redis.command("ZREM", "#{@prefix}delayed", raw) == 1
            env = Envelope.from_json(raw)
            @redis.lpush("#{@prefix}#{env.queue}", raw)
          end
        end
      end

      def ack(envelope : Envelope) : Nil
      end

      def release(envelope : Envelope, delay : Time::Span, attempt : Bool = true) : Nil
        push(envelope.copy_with(attempts: envelope.attempts + (attempt ? 1 : 0), available_at: Time.utc + delay))
      end

      def size(queue : String) : Int64
        @redis.command("LLEN", "#{@prefix}#{queue}").as?(Int64) || 0_i64
      end
    end

    @@driver : Driver?
    @@faked : Array(Job)? = nil

    def self.driver : Driver
      @@driver ||= begin
        config = Silth.config
        case config.string("queue.driver", Silth.test? ? "sync" : "memory")
        when "sync"     then SyncDriver.new
        when "memory"   then MemoryDriver.new
        when "database" then DatabaseDriver.new(config.string?("queue.connection"))
        when "redis"    then RedisDriver.new(config.string("queue.url", ENV["REDIS_URL"]? || "redis://localhost:6379/0"))
        else                 raise ConfigError.new("Unknown queue driver '#{config.string("queue.driver")}'")
        end
      end
    end

    def self.driver=(driver : Driver) : Nil
      @@driver = driver
    end

    def self.push(job : Job, queue : String, delay : Time::Span? = nil) : String?
      id = Crypto.uuid7
      if ttl = job.class.unique_for
        return nil unless Silth.cache.add(unique_lock(job), id, ttl)
      end
      if faked = @@faked
        job.job_id = id
        faked << job
        return id
      end
      envelope = Envelope.new(id, job.class.name, queue, job.to_json, 0, Time.utc + (delay || Time::Span.zero))
      Instrument.publish(Instrument::Job.new(job.class.name, queue, "queued"))
      driver.push(envelope)
      id
    end

    # Executes one envelope with retry/failure handling.
    def self.execute(envelope : Envelope, driver : Driver) : Nil
      job = Job.deserialize(envelope.job, envelope.payload)
      job.attempts = envelope.attempts
      job.job_id = envelope.id
      DB.reset_stickiness # each job reads from replicas until it writes
      if driver.deferred? && (wait = throttle(envelope.queue, job))
        driver.release(envelope, wait, attempt: false)
        return
      end
      if (batch_id = job.batch_id) && Batch.cancelled?(batch_id)
        driver.ack(envelope)
        finished(job, envelope, failed: false)
        Log.info { "Skipped #{envelope.job} (batch #{batch_id} cancelled)" }
        return
      end
      started = Time.instant
      begin
        Telemetry.trace("job #{envelope.job}", :consumer, {"messaging.destination.name" => envelope.queue}) do
          Concurrency.timeout(job.class.timeout) { job.perform; nil }
        end
        driver.ack(envelope)
        finished(job, envelope, failed: false)
        Instrument.publish(Instrument::Job.new(envelope.job, envelope.queue, "processed", Time.instant - started))
        Log.info { "Processed #{envelope.job} (#{(Time.instant - started).total_milliseconds.round(1)}ms)" }
      rescue ex
        Instrument.publish(Instrument::Job.new(envelope.job, envelope.queue, "failed", Time.instant - started))
        if envelope.attempts + 1 < job.class.max_retries
          delay = job.backoff(envelope.attempts + 1)
          Log.warn { "#{envelope.job} failed (attempt #{envelope.attempts + 1}), retrying in #{delay.total_seconds.to_i}s: #{ex.message}" }
          driver.release(envelope, delay)
        else
          Log.error(exception: ex) { "#{envelope.job} failed permanently" }
          job.failed(ex) rescue nil
          ErrorReporter.report(ex)
          driver.fail(envelope, ex)
          finished(job, envelope, failed: true)
        end
      end
    end

    # A job is done for good: release its unique lock, update its batch.
    private def self.finished(job : Job, envelope : Envelope, failed : Bool) : Nil
      Silth.cache.delete(unique_lock(job)) if job.class.unique_for
      job.batch_id.try { |id| Batch.job_processed(id, envelope.id, failed) }
    end

    private def self.unique_lock(job : Job) : String
      "silth:unique-job:#{job.unique_key}"
    end

    # Time to wait when the queue's or the job's rate limit is reached (nil: go).
    def self.throttle(queue : String, job : Job) : Time::Span?
      limits = [] of {String, Int32, Time::Span}
      rate_limit(queue).try { |(limit, period)| limits << {"queue:#{queue}", limit, period} }
      job.class.rate_limit.try { |(limit, period)| limits << {"job:#{job.class.name}", limit, period} }
      limits.each do |(key, limit, period)|
        result = RateLimit.hit("silth:#{key}", limit, period)
        return (result.retry_after.seconds + rand(250).milliseconds) unless result.allowed?
      end
      nil
    end

    # `queue.rate_limits` in config/queue.yml: `{mail: "10/1s", api: "100/1m"}`.
    def self.rate_limit(queue : String) : {Int32, Time::Span}?
      spec = Silth.config.string?("queue.rate_limits.#{queue}") || return nil
      m = spec.match(/\A(\d+)\s*\/\s*(\d*)\s*(s|m|h)\z/) || raise ConfigError.new("Invalid rate limit '#{spec}' for queue #{queue} (use 10/1s, 100/1m, 1000/1h)")
      amount = m[2].empty? ? 1 : m[2].to_i
      period = case m[3]
               when "s" then amount.seconds
               when "m" then amount.minutes
               else          amount.hours
               end
      {m[1].to_i, period}
    end

    # Creates the queue tables when missing (no DDL otherwise: on MySQL it would
    # commit the transaction a job is dispatched from).
    def self.ensure_tables(db : DB::Database) : Nil
      return if db.table_exists?(DatabaseDriver::TABLE) && db.table_exists?("silth_failed_jobs")
      schema = DB::Schema.new(db)
      schema.create_table(DatabaseDriver::TABLE, if_not_exists: true) do |t|
        t.id
        t.string :uid, null: false, unique: true
        t.string :job, null: false
        t.string :queue, null: false, index: true
        t.text :payload, null: false
        t.integer :attempts, default: 0
        t.timestamp :available_at, null: false
        t.timestamp :reserved_at
        t.string :token
        t.timestamp :created_at
      end
      schema.create_table("silth_failed_jobs", if_not_exists: true) do |t|
        t.id
        t.string :uid, null: false
        t.string :job, null: false
        t.string :queue, null: false
        t.text :payload, null: false
        t.text :exception
        t.timestamp :failed_at
      end
    end

    @@failures = Deque(NamedTuple(job: String, queue: String, error: String, at: Time)).new

    def self.record_failure(envelope : Envelope, error : Exception) : Nil
      @@failures << {job: envelope.job, queue: envelope.queue, error: error.message || error.class.name, at: Time.utc}
      @@failures.shift if @@failures.size > 200
      if DB.configured? && driver.is_a?(DatabaseDriver)
        DB.connection.table("silth_failed_jobs").insert({
          "uid" => envelope.id.as(DB::Value), "job" => envelope.job.as(DB::Value), "queue" => envelope.queue.as(DB::Value),
          "payload" => envelope.payload.as(DB::Value), "exception" => error.inspect_with_backtrace.as(DB::Value), "failed_at" => Time.utc.as(DB::Value),
        }, returning: nil)
      end
    end

    def self.recent_failures
      @@failures
    end

    # Processes jobs with `concurrency` fibers until `stop` is called.
    class Worker
      getter? running = false

      def initialize(@queues : Array(String) = ["default"], @concurrency : Int32 = 4, @sleep : Time::Span = 1.second, @driver : Driver = Queue.driver)
      end

      def run : Nil
        @running = true
        Log.info { "Worker started: queues=#{@queues.join(",")} concurrency=#{@concurrency} driver=#{@driver.class.name.split("::").last}" }
        done = ::Channel(Nil).new
        @concurrency.times do |i|
          spawn(name: "silth-worker-#{i}") do
            while @running
              if envelope = (@driver.pop(@queues) rescue nil)
                Queue.execute(envelope, @driver)
              else
                sleep @sleep
              end
            end
            done.send(nil)
          end
        end
        @concurrency.times { done.receive }
        Log.info { "Worker stopped" }
      end

      # Processes jobs until the queues are empty (tests, one-off commands).
      def drain : Int32
        count = 0
        while envelope = @driver.pop(@queues)
          Queue.execute(envelope, @driver)
          count += 1
        end
        count
      end

      def stop : Nil
        @running = false
      end
    end

    # --- testing -------------------------------------------------------------

    def self.fake : Nil
      @@faked = [] of Job
    end

    def self.unfake : Nil
      @@faked = nil
    end

    def self.pushed : Array(Job)
      @@faked || [] of Job
    end

    def self.pushed?(type : T.class) : Bool forall T
      pushed.any?(T)
    end
  end
end
