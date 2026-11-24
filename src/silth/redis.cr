require "socket"
require "openssl"

module Silth
  # Minimal Redis client (RESP2) used by the cache, queue, rate limiter and pub/sub.
  #
  # ```
  # redis = Silth::Redis.new("redis://localhost:6379/0")
  # redis.set("greeting", "hi", ex: 60)
  # redis.get("greeting") # => "hi"
  # redis.command("HSET", "user:1", "name", "Ada")
  # ```
  class Redis
    alias Reply = Nil | String | Int64 | Array(Reply)

    class Error < Silth::Error; end

    @socket : IO?
    @mutex = Mutex.new

    def initialize(@url : String = ENV["REDIS_URL"]? || "redis://localhost:6379/0")
    end

    private def connection : IO
      if s = @socket
        return s
      end
      uri = URI.parse(@url)
      tcp = TCPSocket.new(uri.host || "localhost", uri.port || 6379, connect_timeout: 5.seconds)
      tcp.tcp_nodelay = true
      io = if uri.scheme == "rediss"
             OpenSSL::SSL::Socket::Client.new(tcp, OpenSSL::SSL::Context::Client.new, sync_close: true, hostname: uri.host)
           else
             tcp
           end
      @socket = io
      if pass = uri.password
        user = uri.user.presence
        user ? raw(io, ["AUTH", user, pass]) : raw(io, ["AUTH", pass])
      end
      db = uri.path.lchop('/')
      raw(io, ["SELECT", db]) unless db.empty? || db == "0"
      io
    end

    def command(*args) : Reply
      command(args.to_a.map(&.to_s))
    end

    def command(args : Array(String)) : Reply
      @mutex.synchronize do
        begin
          raw(connection, args)
        rescue ex : IO::Error
          @socket.try &.close rescue nil
          @socket = nil
          raw(connection, args)
        end
      end
    end

    private def raw(io : IO, args : Array(String)) : Reply
      io << '*' << args.size << "\r\n"
      args.each { |a| io << '$' << a.bytesize << "\r\n" << a << "\r\n" }
      io.flush
      read_reply(io)
    end

    def read_reply(io : IO) : Reply
      line = io.gets("\r\n", chomp: true) || raise IO::EOFError.new("Redis connection closed")
      case line[0]
      when '+' then line[1..]
      when '-' then raise Error.new(line[1..])
      when ':' then line[1..].to_i64
      when '$'
        len = line[1..].to_i
        return nil if len < 0
        data = Bytes.new(len)
        io.read_fully(data)
        io.skip(2)
        String.new(data)
      when '*'
        count = line[1..].to_i
        return nil if count < 0
        items = [] of Reply
        count.times { items << read_reply(io).as(Reply) }
        items.as(Reply)
      else
        raise Error.new("Unexpected Redis reply: #{line}")
      end
    end

    def get(key : String) : String?
      command("GET", key).as?(String)
    end

    def set(key : String, value : String, ex : Int32? = nil, nx : Bool = false) : Bool
      args = ["SET", key, value]
      args.concat(["EX", ex.to_s]) if ex
      args << "NX" if nx
      command(args) == "OK"
    end

    def del(*keys : String) : Int64
      command(["DEL"] + keys.to_a).as?(Int64) || 0_i64
    end

    def incrby(key : String, by : Int64 = 1) : Int64
      command("INCRBY", key, by).as(Int64)
    end

    def expire(key : String, seconds : Int32) : Nil
      command("EXPIRE", key, seconds)
    end

    def ttl(key : String) : Int64
      command("TTL", key).as?(Int64) || -2_i64
    end

    def publish(channel : String, message : String) : Int64
      command("PUBLISH", channel, message).as?(Int64) || 0_i64
    end

    def lpush(key : String, value : String) : Int64
      command("LPUSH", key, value).as?(Int64) || 0_i64
    end

    def brpop(key : String, timeout : Int32 = 5) : String?
      reply = command("BRPOP", key, timeout)
      reply.as?(Array(Reply)).try(&.[1]?).as?(String)
    end

    def zadd(key : String, score : Float64 | Int64, member : String) : Nil
      command("ZADD", key, score, member)
    end

    def ping : Bool
      command("PING") == "PONG"
    rescue
      false
    end

    # Blocking subscription on a dedicated connection.
    def subscribe(*channels : String, & : String, String ->) : Nil
      uri = URI.parse(@url)
      io = TCPSocket.new(uri.host || "localhost", uri.port || 6379)
      raw(io, ["AUTH", uri.password.not_nil!]) if uri.password
      io << '*' << (channels.size + 1) << "\r\n$9\r\nSUBSCRIBE\r\n"
      channels.each { |c| io << '$' << c.bytesize << "\r\n" << c << "\r\n" }
      io.flush
      loop do
        reply = read_reply(io).as?(Array(Reply)) || next
        if reply[0]? == "message"
          yield reply[1].to_s, reply[2].to_s
        end
      end
    end

    def close : Nil
      @socket.try &.close
      @socket = nil
    end
  end
end
