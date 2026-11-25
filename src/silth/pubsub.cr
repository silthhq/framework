module Silth
  # In-process publish/subscribe used by live components, channels and
  # `Broadcast`. With several server nodes, an adapter relays every message to the
  # other nodes, configured in `config/realtime.yml`:
  #
  # ```yaml
  # pubsub: redis                  # memory (one process) | redis | postgres
  # redis_url: ${REDIS_URL:-redis://localhost:6379/0}
  # connection: primary            # postgres: database connection used for LISTEN/NOTIFY
  # channel: silth_pubsub          # Redis channel / PostgreSQL notification channel
  # ```
  #
  # ```
  # id = Silth::PubSub.subscribe("orders") { |event, message| puts event }
  # Silth::PubSub.publish("orders", "created", %({"id": 1})) # every node's "orders" subscribers
  # Silth::PubSub.unsubscribe("orders", id)
  # ```
  module PubSub
    Log = ::Log.for("silth.pubsub")

    alias Handler = Proc(String, String, Nil)

    @@subscribers = {} of String => Hash(UInt64, Handler)
    @@mutex = Mutex.new
    @@seq = 0_u64
    @@adapter : Adapter? = nil
    @@node = Crypto.hex_token(6)

    # Relays messages between nodes. `publish` sends an envelope (JSON) to the
    # other nodes; `start` listens and hands every envelope received to the block.
    abstract class Adapter
      abstract def name : String
      abstract def publish(payload : String) : Nil
      abstract def start(&on_message : String -> Nil) : Nil
      abstract def stop : Nil

      # True once the listener is connected.
      getter? ready = false

      # Runs *block* again after failures, with an increasing pause.
      protected def with_reconnect(what : String, & : ->) : Nil
        pause = 0.2
        until stopped?
          begin
            yield
          rescue ex
            break if stopped?
            @ready = false
            Log.warn(exception: ex) { "#{what} lost; reconnecting in #{pause}s" }
            sleep pause.seconds
            pause = {pause * 2, 10.0}.min
          end
        end
      end

      @stopped = false

      def stopped? : Bool
        @stopped
      end
    end

    # Redis PUBLISH/SUBSCRIBE.
    class RedisAdapter < Adapter
      @subscriber : Redis? = nil

      def initialize(@url : String, @channel : String = "silth:pubsub")
        @publisher = Redis.new(@url)
      end

      def name : String
        "redis"
      end

      def publish(payload : String) : Nil
        @publisher.publish(@channel, payload)
      end

      def start(&on_message : String -> Nil) : Nil
        spawn(name: "silth-pubsub-redis") do
          with_reconnect("Redis pub/sub") do
            client = @subscriber = Redis.new(@url)
            client.subscribe(@channel, ready: ->{ @ready = true; nil }) { |_, payload| on_message.call(payload) }
          end
        end
      end

      def stop : Nil
        @stopped = true
        @subscriber.try &.close
        @publisher.close
      end
    end

    # PostgreSQL LISTEN/NOTIFY on a dedicated connection. NOTIFY payloads are
    # limited to 8000 bytes: bigger messages go through an UNLOGGED table and the
    # notification carries their id. Published inside a transaction, a message is
    # sent at commit (and dropped on rollback).
    class PostgresAdapter < Adapter
      PAYLOAD_LIMIT  = 7900
      OVERFLOW_TABLE = "silth_pubsub_messages"

      @listener : DB::Postgres::Connection? = nil
      @overflow_ready = false
      @overflow_count = 0

      def initialize(@db : DB::Database, @channel : String = "silth_pubsub")
        raise Error.new("The postgres pub/sub adapter needs a PostgreSQL connection (got #{@db.dialect.name})") unless @db.dialect.name == "postgres"
      end

      def name : String
        "postgres"
      end

      def publish(payload : String) : Nil
        payload = "@#{store_overflow(payload)}" if payload.bytesize > PAYLOAD_LIMIT
        @db.query("SELECT pg_notify(?, ?)", [@channel, payload] of DB::Value)
      end

      def start(&on_message : String -> Nil) : Nil
        spawn(name: "silth-pubsub-postgres") do
          with_reconnect("PostgreSQL LISTEN") do
            conn = @listener = DB::Postgres::Connection.new(listener_url)
            begin
              conn.exec_script("LISTEN #{@db.dialect.quote(@channel)}")
              @ready = true
              listen(conn, on_message)
            ensure
              conn.close
            end
          end
        end
      end

      def stop : Nil
        @stopped = true
        @listener.try &.close
      end

      # The database URL, named `silth-pubsub` in pg_stat_activity.
      private def listener_url : URI
        url = @db.url.dup
        params = url.query_params
        params["application_name"] = "silth-pubsub"
        url.query = params.to_s
        url
      end

      private def listen(conn : DB::Postgres::Connection, on_message : String -> Nil) : Nil
        until stopped?
          if notification = conn.wait_for_notification(30.seconds)
            next unless notification.channel == @channel
            payload = notification.payload
            payload = load_overflow(payload[1..].to_i64) if payload.starts_with?('@')
            payload.try { |p| on_message.call(p) }
          else
            conn.query("SELECT 1", [] of DB::Value) # keeps the connection alive
          end
        end
      end

      private def store_overflow(payload : String) : Int64
        unless @overflow_ready
          @db.exec_script("CREATE UNLOGGED TABLE IF NOT EXISTS #{OVERFLOW_TABLE} (id BIGSERIAL PRIMARY KEY, " \
                          "payload TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now())")
          @overflow_ready = true
        end
        if (@overflow_count += 1) % 100 == 1
          @db.query("DELETE FROM #{OVERFLOW_TABLE} WHERE created_at < now() - interval '5 minutes'")
        end
        DB.as_i64(@db.scalar("INSERT INTO #{OVERFLOW_TABLE} (payload) VALUES (?) RETURNING id", [payload] of DB::Value))
      end

      private def load_overflow(id : Int64) : String?
        @db.scalar("SELECT payload FROM #{OVERFLOW_TABLE} WHERE id = ?", [id] of DB::Value).try(&.to_s)
      end
    end

    def self.subscribe(topic : String, &handler : String, String -> Nil) : UInt64
      @@mutex.synchronize do
        @@seq += 1
        (@@subscribers[topic] ||= {} of UInt64 => Handler)[@@seq] = handler
        @@seq
      end
    end

    def self.unsubscribe(topic : String, id : UInt64) : Nil
      @@mutex.synchronize do
        if subs = @@subscribers[topic]?
          subs.delete(id)
          @@subscribers.delete(topic) if subs.empty?
        end
      end
    end

    def self.subscribers(topic : String) : Int32
      @@mutex.synchronize { @@subscribers[topic]?.try(&.size) || 0 }
    end

    # Publishes `message` (JSON string) under `event` to every subscriber of
    # `topic`, on this node and, through the adapter, on the others.
    def self.publish(topic : String, event : String, message : String) : Nil
      deliver_local(topic, event, message)
      if adapter = @@adapter
        begin
          adapter.publish({node: @@node, topic: topic, event: event, message: message}.to_json)
        rescue ex
          Log.error(exception: ex) { "Could not relay #{topic}/#{event} through #{adapter.name}" }
        end
      end
    end

    def self.deliver_local(topic : String, event : String, message : String) : Nil
      handlers = @@mutex.synchronize { @@subscribers[topic]?.try(&.values) || [] of Handler }
      handlers.each { |h| h.call(event, message) rescue nil }
      # Wildcard subscribers: "chat:*"
      wildcard = topic.includes?(':') ? topic.split(':').first + ":*" : nil
      if wildcard && wildcard != topic
        @@mutex.synchronize { @@subscribers[wildcard]?.try(&.values) || [] of Handler }.each { |h| h.call(event, message) rescue nil }
      end
    end

    # An envelope relayed by another node.
    def self.receive(payload : String) : Nil
      data = JSON.parse(payload)
      return if data["node"].as_s == @@node
      deliver_local(data["topic"].as_s, data["event"].as_s, data["message"].as_s)
    rescue ex
      Log.warn(exception: ex) { "Ignored malformed pub/sub message" }
    end

    def self.adapter : Adapter?
      @@adapter
    end

    # Replaces the adapter (stopping the previous one) and starts listening.
    def self.adapter=(adapter : Adapter?) : Nil
      @@adapter.try &.stop
      @@adapter = adapter
      adapter.try &.start { |payload| receive(payload) }
    end

    # This process' identity in relayed messages.
    def self.node : String
      @@node
    end

    # Configures the adapter from `realtime.*` (config/realtime.yml).
    def self.boot(config : Config) : Nil
      channel = config.string?("realtime.channel")
      case kind = config.string("realtime.pubsub", "memory")
      when "memory"
        self.adapter = nil
      when "redis"
        url = config.string("realtime.redis_url", ENV["REDIS_URL"]? || "redis://localhost:6379/0")
        self.adapter = RedisAdapter.new(url, channel || "silth:pubsub")
      when "postgres", "postgresql"
        db = DB.connection(config.string?("realtime.connection"))
        self.adapter = PostgresAdapter.new(db, channel || "silth_pubsub")
      else
        raise Error.new("Unknown realtime.pubsub adapter '#{kind}' (use memory, redis or postgres)")
      end
    end

    def self.boot_redis(url : String) : Nil
      self.adapter = RedisAdapter.new(url)
    end
  end
end
