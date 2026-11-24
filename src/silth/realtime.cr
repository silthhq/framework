require "http/web_socket"

module Silth
  # Pub/sub fan-out used by channels, broadcasts and live components.
  # In-memory by default; set `realtime.pubsub: redis` to share across servers.
  module PubSub
    alias Handler = Proc(String, String, Nil)

    @@subscribers = {} of String => Hash(UInt64, Handler)
    @@mutex = Mutex.new
    @@seq = 0_u64
    @@redis : Redis? = nil
    @@node = Crypto.hex_token(6)

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

    # Publishes `message` (JSON string) under `event` to every subscriber of `topic`.
    def self.publish(topic : String, event : String, message : String) : Nil
      deliver_local(topic, event, message)
      @@redis.try &.publish("silth:pubsub", {node: @@node, topic: topic, event: event, message: message}.to_json)
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

    def self.boot_redis(url : String) : Nil
      @@redis = Redis.new(url)
      spawn(name: "silth-pubsub") do
        Redis.new(url).subscribe("silth:pubsub") do |_, payload|
          data = JSON.parse(payload)
          next if data["node"].as_s == @@node
          deliver_local(data["topic"].as_s, data["event"].as_s, data["message"].as_s)
        end
      end
    end
  end

  # Push data to WebSocket clients from anywhere (controllers, jobs, listeners).
  #
  # ```
  # Silth::Broadcast.to("orders:#{order.id}", "status", {status: "shipped"})
  # ```
  module Broadcast
    def self.to(topic : String, event : String, payload) : Nil
      PubSub.publish(topic, event, payload.is_a?(String) ? payload : payload.to_json)
    end
  end

  # A WebSocket connection multiplexing channel topics.
  class Socket
    getter id : String = Crypto.hex_token(8)
    getter ws : HTTP::WebSocket
    getter user : Auth::Authenticatable?
    getter assigns = {} of String => String
    getter joined = {} of String => {Channel, UInt64}
    @mutex = Mutex.new

    def initialize(@ws : HTTP::WebSocket, @user : Auth::Authenticatable?)
    end

    # Messages are JSON arrays: `[ref, topic, event, payload]`.
    def send(ref : String?, topic : String, event : String, payload : String) : Nil
      @mutex.synchronize do
        @ws.send(%([#{ref.try(&.to_json) || "null"},#{topic.to_json},#{event.to_json},#{payload}]))
      end
    rescue
      nil
    end

    def close : Nil
      @joined.each do |topic, (channel, sub)|
        channel.leave rescue nil
        PubSub.unsubscribe(topic, sub)
        Presence.untrack(topic, @id)
      end
      @joined.clear
    end
  end

  # Real-time channels (Phoenix style).
  #
  # ```
  # class ChatChannel < Silth::Channel
  #   topic "chat:*"
  #
  #   def join(payload : JSON::Any) : Bool
  #     !socket.user.nil?                      # authorize
  #   end
  #
  #   def handle_in(event : String, payload : JSON::Any) : Nil
  #     broadcast("message", {user: socket.user.try(&.auth_id), body: payload["body"].as_s})
  #   end
  # end
  # ```
  #
  # Client: `const chat = silth.socket().channel("chat:lobby"); chat.on("message", m => …); chat.join()`.
  abstract class Channel
    getter socket : Socket
    getter topic : String

    def initialize(@socket : Socket, @topic : String)
    end

    def self.pattern : String
      raise Silth::Error.new("#{name} must declare `topic \"name:*\"`")
    end

    macro topic(pattern)
      def self.pattern : String
        {{pattern}}
      end
    end

    def join(payload : JSON::Any) : Bool
      true
    end

    def handle_in(event : String, payload : JSON::Any) : Nil
    end

    def leave : Nil
    end

    # Sends to every subscriber of this topic (including this socket).
    def broadcast(event : String, payload) : Nil
      Broadcast.to(@topic, event, payload)
    end

    # Sends only to this socket.
    def push(event : String, payload) : Nil
      @socket.send(nil, @topic, event, payload.is_a?(String) ? payload : payload.to_json)
    end

    def track_presence(meta : Hash(String, String) = {} of String => String) : Nil
      Presence.track(@topic, @socket.id, @socket.user.try(&.auth_id) || "guest", meta)
    end

    def self.matches?(topic : String) : Bool
      p = pattern
      p.ends_with?('*') ? topic.starts_with?(p.rchop('*')) : topic == p
    end

    # Finds the channel class handling `topic`.
    def self.build(socket : Socket, topic : String) : Channel?
      {% begin %}
        {% for klass in @type.all_subclasses.reject(&.abstract?) %}
          return {{klass}}.new(socket, topic) if {{klass}}.matches?(topic)
        {% end %}
      {% end %}
      nil
    end
  end

  # Who is connected to a topic; broadcasts `presence_diff` on joins and leaves.
  module Presence
    record Entry, key : String, meta : Hash(String, String), joined_at : Time

    @@state = {} of String => Hash(String, Entry)
    @@mutex = Mutex.new

    def self.track(topic : String, socket_id : String, key : String, meta = {} of String => String) : Nil
      @@mutex.synchronize { (@@state[topic] ||= {} of String => Entry)[socket_id] = Entry.new(key, meta, Time.utc) }
      Broadcast.to(topic, "presence_diff", {joins: {key => meta}, leaves: {} of String => String})
    end

    def self.untrack(topic : String, socket_id : String) : Nil
      entry = @@mutex.synchronize { @@state[topic]?.try(&.delete(socket_id)) }
      Broadcast.to(topic, "presence_diff", {joins: {} of String => String, leaves: {entry.key => entry.meta}}) if entry
    end

    def self.list(topic : String) : Hash(String, Hash(String, String))
      @@mutex.synchronize do
        (@@state[topic]? || {} of String => Entry).values.to_h { |e| {e.key, e.meta} }
      end
    end
  end

  # WebSocket endpoint serving channels (`/_silth/socket`) and live components (`/_silth/live`).
  module Realtime
    Log = ::Log.for("silth.realtime")

    def self.upgrade?(ctx : Context) : Bool
      ctx.header("Upgrade").try(&.downcase) == "websocket"
    end

    # Runs `block` with the session-authenticated user, then hands the socket over.
    def self.accept(ctx : Context, &block : HTTP::WebSocket, Auth::Authenticatable? -> Nil) : Nil
      user = resolve_user(ctx)
      handler = HTTP::WebSocketHandler.new { |ws, _| block.call(ws, user) }
      ctx.mark_responded!
      handler.call(ctx.raw)
    end

    # Authenticates WebSocket upgrades with the regular session cookie.
    def self.resolve_user(ctx : Context) : Auth::Authenticatable?
      session = Silth.session_store.load(ctx) || return nil
      id = session[Auth::SESSION_ID]? || return nil
      Auth.find_user(id, session[Auth::SESSION_TYPE]?)
    rescue
      nil
    end

    def self.serve_channels(ctx : Context) : Nil
      accept(ctx) do |ws, user|
        socket = Socket.new(ws, user)
        ws.on_message do |raw|
          handle_channel_message(socket, raw)
        end
        ws.on_close { socket.close }
      end
    end

    private def self.handle_channel_message(socket : Socket, raw : String) : Nil
      msg = JSON.parse(raw).as_a
      ref = msg[0]?.try(&.as_s?)
      topic = msg[1].as_s
      event = msg[2].as_s
      payload = msg[3]? || JSON::Any.new(nil)
      case event
      when "heartbeat"
        socket.send(ref, topic, "reply", %({"status":"ok"}))
      when "join"
        if channel = Channel.build(socket, topic)
          if channel.join(payload)
            sub = PubSub.subscribe(topic) { |ev, message| socket.send(nil, topic, ev, message) }
            socket.joined[topic] = {channel, sub}
            socket.send(ref, topic, "reply", %({"status":"ok"}))
          else
            socket.send(ref, topic, "reply", %({"status":"error","reason":"unauthorized"}))
          end
        else
          socket.send(ref, topic, "reply", %({"status":"error","reason":"no channel for topic"}))
        end
      when "leave"
        if entry = socket.joined.delete(topic)
          entry[0].leave
          PubSub.unsubscribe(topic, entry[1])
          Presence.untrack(topic, socket.id)
        end
        socket.send(ref, topic, "reply", %({"status":"ok"}))
      else
        if entry = socket.joined[topic]?
          entry[0].handle_in(event, payload)
          socket.send(ref, topic, "reply", %({"status":"ok"})) if ref
        end
      end
    rescue ex
      Log.warn(exception: ex) { "Invalid channel message" }
    end
  end

  # Development live reload: browsers reconnect after a server restart and reload.
  class DevReloadMiddleware < Middleware
    @@clients = [] of HTTP::WebSocket
    @@mutex = Mutex.new

    def call(ctx : Context, chain : Chain) : Nil
      if ctx.path == "/_silth/livereload" && Realtime.upgrade?(ctx)
        Realtime.accept(ctx) do |ws, _|
          @@mutex.synchronize { @@clients << ws }
          ws.on_close { @@mutex.synchronize { @@clients.delete(ws) } }
        end
      else
        chain.next(ctx)
      end
    end

    def self.notify(message : String = "reload") : Nil
      @@mutex.synchronize { @@clients.each { |c| c.send(message) rescue nil } }
    end

    # Watches `assets/` and hot-swaps CSS in open browsers.
    def self.watch_assets(dir : String = "assets") : Nil
      spawn(name: "silth-asset-watch") do
        mtimes = {} of String => Time
        loop do
          changed_css = false
          changed_other = false
          Dir.glob(File.join(dir, "**", "*")).each do |f|
            next unless File.file?(f)
            m = File.info(f).modification_time
            if (prev = mtimes[f]?) && prev != m
              f.ends_with?(".css") ? (changed_css = true) : (changed_other = true)
            end
            mtimes[f] = m
          end
          notify("css") if changed_css
          notify("reload") if changed_other
          sleep 400.milliseconds
        end
      end
    end
  end
end
