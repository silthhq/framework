module Silth
  # Cache stores with a single API.
  #
  # ```yaml
  # # config/cache.yml
  # default: memory          # memory | file | database | postgres | redis | null
  # stores:
  #   file: { path: tmp/cache }
  #   redis: { url: ${REDIS_URL:-redis://localhost:6379/1} }
  # ```
  #
  # ```
  # Silth.cache.fetch("stats", 10.minutes) { compute_stats.to_json }
  # Silth.cache.fetch_json("posts:top", Array(String), 1.hour) { ["a", "b"] }
  # Silth.cache.lock("report", 30.seconds) { generate_report }
  # ```
  abstract class CacheStore
    getter name : String

    def initialize(@name : String)
    end

    abstract def read(key : String) : String?
    abstract def write(key : String, value : String, ttl : Time::Span?) : Nil
    abstract def delete(key : String) : Bool
    abstract def increment(key : String, by : Int64 = 1, ttl : Time::Span? = nil) : Int64
    abstract def clear : Nil

    # Stores only if absent. Returns true when written (atomic on redis/database).
    abstract def add(key : String, value : String, ttl : Time::Span?) : Bool

    def get(key : String) : String?
      value = read(key)
      Instrument.publish(Instrument::Cache.new("get", key, !value.nil?, @name))
      value
    end

    def set(key : String, value : String, ttl : Time::Span? = nil) : Nil
      Instrument.publish(Instrument::Cache.new("set", key, true, @name))
      write(key, value, ttl)
    end

    def exists?(key : String) : Bool
      !read(key).nil?
    end

    def fetch(key : String, ttl : Time::Span? = nil, & : -> String) : String
      if cached = get(key)
        return cached
      end
      value = yield
      set(key, value, ttl)
      value
    end

    def remember(key : String, ttl : Time::Span? = nil, & : -> String) : String
      fetch(key, ttl) { yield }
    end

    def fetch_json(key : String, type : T.class, ttl : Time::Span? = nil, & : -> T) : T forall T
      if cached = get(key)
        begin
          return T.from_json(cached)
        rescue JSON::ParseException
        end
      end
      value = yield
      set(key, value.to_json, ttl)
      value
    end

    def pull(key : String) : String?
      value = read(key)
      delete(key) if value
      value
    end

    def decrement(key : String, by : Int64 = 1) : Int64
      increment(key, -by)
    end

    # Runs the block only if the lock can be acquired. Returns nil otherwise.
    def lock(key : String, ttl : Time::Span = 10.seconds, &)
      token = Crypto.token(8)
      return nil unless add("lock:#{key}", token, ttl)
      begin
        yield
      ensure
        delete("lock:#{key}") if read("lock:#{key}") == token
      end
    end
  end

  class MemoryCache < CacheStore
    record Entry, value : String, expires_at : Time?

    def initialize(name : String = "memory", @max_entries : Int32 = 10_000)
      super(name)
      @data = {} of String => Entry
      @mutex = Mutex.new
    end

    def read(key : String) : String?
      @mutex.synchronize do
        entry = @data[key]? || return nil
        if (exp = entry.expires_at) && exp < Time.utc
          @data.delete(key)
          return nil
        end
        entry.value
      end
    end

    def write(key : String, value : String, ttl : Time::Span?) : Nil
      @mutex.synchronize do
        @data.delete(@data.first_key) if @data.size >= @max_entries && !@data.has_key?(key)
        @data[key] = Entry.new(value, ttl.try { |t| Time.utc + t })
      end
    end

    def add(key : String, value : String, ttl : Time::Span?) : Bool
      @mutex.synchronize do
        if (entry = @data[key]?) && (entry.expires_at.nil? || entry.expires_at.not_nil! > Time.utc)
          return false
        end
        @data[key] = Entry.new(value, ttl.try { |t| Time.utc + t })
        true
      end
    end

    def delete(key : String) : Bool
      @mutex.synchronize { !@data.delete(key).nil? }
    end

    def increment(key : String, by : Int64 = 1, ttl : Time::Span? = nil) : Int64
      @mutex.synchronize do
        entry = @data[key]?
        entry = nil if entry && (exp = entry.expires_at) && exp < Time.utc
        current = entry.try(&.value.to_i64?) || 0_i64
        value = current + by
        @data[key] = Entry.new(value.to_s, entry.try(&.expires_at) || ttl.try { |t| Time.utc + t })
        value
      end
    end

    def clear : Nil
      @mutex.synchronize { @data.clear }
    end

    def size : Int32
      @data.size
    end
  end

  class FileCache < CacheStore
    def initialize(name : String = "file", @dir : String = "tmp/cache")
      super(name)
      Dir.mkdir_p(@dir)
    end

    private def path(key : String) : String
      digest = Digest::SHA256.hexdigest(key)
      File.join(@dir, digest[0, 2], digest)
    end

    def read(key : String) : String?
      file = path(key)
      return nil unless File.exists?(file)
      content = File.read(file)
      expires, _, value = content.partition('\n')
      if (exp = expires.to_i64?) && exp > 0 && exp < Time.utc.to_unix
        File.delete?(file)
        return nil
      end
      value
    rescue File::Error
      nil
    end

    def write(key : String, value : String, ttl : Time::Span?) : Nil
      file = path(key)
      Dir.mkdir_p(File.dirname(file))
      tmp = "#{file}.#{Random::Secure.hex(4)}"
      File.write(tmp, "#{ttl ? (Time.utc + ttl).to_unix : 0}\n#{value}")
      File.rename(tmp, file)
    end

    def add(key : String, value : String, ttl : Time::Span?) : Bool
      return false if read(key)
      write(key, value, ttl)
      true
    end

    def delete(key : String) : Bool
      file = path(key)
      File.exists?(file) ? (File.delete(file); true) : false
    end

    def increment(key : String, by : Int64 = 1, ttl : Time::Span? = nil) : Int64
      value = (read(key).try(&.to_i64?) || 0_i64) + by
      write(key, value.to_s, ttl)
      value
    end

    def clear : Nil
      FileUtils.rm_rf(@dir)
      Dir.mkdir_p(@dir)
    end
  end

  # Stores entries in the `silth_cache` table (created on first use).
  class DatabaseCache < CacheStore
    TABLE = "silth_cache"
    @ready = false

    def initialize(name : String = "database", @connection : String? = nil)
      super(name)
    end

    # Creates the table now when it is missing.
    def prepare : Nil
      DB::Schema.new(DB.connection(@connection)).ensure_table(TABLE) do |t|
        t.string :key, null: false, unique: true
        t.text :value
        t.bigint :expires_at
      end
      @ready = true
    end

    private def db : DB::Database
      prepare unless @ready
      DB.connection(@connection)
    end

    def read(key : String) : String?
      row = db.table(TABLE).where(key: key).first? || return nil
      exp = DB.as_i64(row["expires_at"])
      if exp > 0 && exp < Time.utc.to_unix
        delete(key)
        return nil
      end
      row["value"].as?(String)
    end

    def write(key : String, value : String, ttl : Time::Span?) : Nil
      exp = ttl ? (Time.utc + ttl).to_unix : 0_i64
      db.table(TABLE).upsert([{"key" => key.as(DB::Value), "value" => value.as(DB::Value), "expires_at" => exp.as(DB::Value)}], ["key"], ["value", "expires_at"])
    end

    def add(key : String, value : String, ttl : Time::Span?) : Bool
      delete(key) if read(key).nil?
      db.table(TABLE).insert({"key" => key.as(DB::Value), "value" => value.as(DB::Value), "expires_at" => (ttl ? (Time.utc + ttl).to_unix : 0_i64).as(DB::Value)}, returning: nil)
      true
    rescue DB::UniqueViolation
      false
    end

    def delete(key : String) : Bool
      db.table(TABLE).where(key: key).delete > 0
    end

    def increment(key : String, by : Int64 = 1, ttl : Time::Span? = nil) : Int64
      db.transaction do
        value = (read(key).try(&.to_i64?) || 0_i64) + by
        write(key, value.to_s, ttl)
        value
      end
    end

    def clear : Nil
      db.table(TABLE).delete
    end
  end

  class RedisCache < CacheStore
    getter redis : Redis

    def initialize(name : String = "redis", url : String = "redis://localhost:6379/1", @prefix : String = "silth:")
      super(name)
      @redis = Redis.new(url)
    end

    def read(key : String) : String?
      @redis.get(@prefix + key)
    end

    def write(key : String, value : String, ttl : Time::Span?) : Nil
      @redis.set(@prefix + key, value, ex: ttl.try(&.total_seconds.ceil.to_i))
    end

    def add(key : String, value : String, ttl : Time::Span?) : Bool
      @redis.set(@prefix + key, value, ex: ttl.try(&.total_seconds.ceil.to_i), nx: true)
    end

    def delete(key : String) : Bool
      @redis.del(@prefix + key) > 0
    end

    def increment(key : String, by : Int64 = 1, ttl : Time::Span? = nil) : Int64
      value = @redis.incrby(@prefix + key, by)
      @redis.expire(@prefix + key, ttl.total_seconds.ceil.to_i) if ttl && value == by
      value
    end

    def clear : Nil
      keys = @redis.command("KEYS", "#{@prefix}*").as?(Array(Redis::Reply)) || [] of Redis::Reply
      keys.each_slice(500) { |slice| @redis.command(["DEL"] + slice.map(&.to_s)) unless slice.empty? }
    end
  end

  class NullCache < CacheStore
    def read(key : String) : String?
      nil
    end

    def write(key : String, value : String, ttl : Time::Span?) : Nil
    end

    def add(key : String, value : String, ttl : Time::Span?) : Bool
      true
    end

    def delete(key : String) : Bool
      false
    end

    def increment(key : String, by : Int64 = 1, ttl : Time::Span? = nil) : Int64
      by
    end

    def clear : Nil
    end
  end

  @@caches = {} of String => CacheStore

  def self.cache(name : String? = nil) : CacheStore
    store_name = name || config.string("cache.default", test? ? "memory" : "memory")
    @@caches[store_name] ||= build_cache(store_name)
  end

  def self.cache=(store : CacheStore) : Nil
    @@caches[config.string("cache.default", "memory")] = store
  end

  def self.build_cache(name : String) : CacheStore
    driver = config.string("cache.stores.#{name}.driver", name)
    case driver
    when "memory"   then MemoryCache.new(name)
    when "file"     then FileCache.new(name, config.string("cache.stores.#{name}.path", "tmp/cache"))
    when "database" then DatabaseCache.new(name, config.string?("cache.stores.#{name}.connection"))
    when "postgres" then PostgresCache.new(name, config.string?("cache.stores.#{name}.connection"), config.string("cache.stores.#{name}.table", PostgresCache::DEFAULT_TABLE))
    when "redis"    then RedisCache.new(name, config.string("cache.stores.#{name}.url", ENV["REDIS_URL"]? || "redis://localhost:6379/1"), config.string("cache.prefix", "silth:"))
    when "null"     then NullCache.new(name)
    else                 raise ConfigError.new("Unknown cache driver '#{driver}'")
    end
  end
end
