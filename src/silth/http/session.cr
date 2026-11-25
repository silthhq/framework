require "json"

module Silth
  # Request session. Values are strings; use JSON for structured data.
  #
  # ```
  # session["cart_id"] = cart.id.to_s
  # session["cart_id"]?   # => "42"
  # session.regenerate    # new identifier (call after login!)
  # ```
  class Session
    getter id : String
    getter data : Hash(String, String)
    getter? changed = false
    getter? destroyed = false
    getter? regenerated = false

    def initialize(@id : String = Crypto.token(24), @data = {} of String => String)
    end

    def [](key : String) : String
      @data[key]
    end

    def []?(key : String) : String?
      @data[key]?
    end

    def []=(key : String, value : String) : String
      @changed = true unless @data[key]? == value
      @data[key] = value
    end

    def delete(key : String) : String?
      @changed = true if @data.has_key?(key)
      @data.delete(key)
    end

    def has_key?(key : String) : Bool
      @data.has_key?(key)
    end

    def pull(key : String) : String?
      delete(key)
    end

    def clear : Nil
      @changed = true
      @data.clear
    end

    # Changes the session identifier while keeping data (prevents fixation).
    # The identifier before the first `regenerate`/`invalidate` of this request
    # (server-side stores delete it, so an old cookie stops working).
    getter previous_id : String? = nil

    def regenerate : Nil
      @previous_id ||= @id
      @id = Crypto.token(24)
      @changed = true
      @regenerated = true
    end

    # Wipes everything and issues a new identifier.
    def invalidate : Nil
      clear
      regenerate
      @destroyed = true
    end

    def touch! : Nil
      @changed = true
    end

    def to_json(json : JSON::Builder) : Nil
      @data.to_json(json)
    end
  end

  # Flash messages survive exactly one redirect.
  #
  # ```
  # flash["success"] = "Post created"   # available on the next request
  # flash.now["error"] = "Invalid"      # available for the current render only
  # ```
  class Flash
    KEY = "_flash"

    getter current : Hash(String, String)
    getter next_messages = {} of String => String

    def initialize(@current = {} of String => String)
    end

    def self.from_session(session : Session) : Flash
      raw = session.pull(KEY)
      messages = raw ? Hash(String, String).from_json(raw) : {} of String => String
      new(messages)
    rescue JSON::ParseException
      new
    end

    def [](key : String) : String
      @current[key]? || @next_messages[key]
    end

    def []?(key : String) : String?
      @current[key]? || @next_messages[key]?
    end

    def []=(key : String, message : String) : String
      @next_messages[key] = message
    end

    def now : Hash(String, String)
      @current
    end

    def keep : Nil
      @next_messages.merge!(@current)
    end

    def each(& : String, String ->)
      @current.each { |k, v| yield k, v }
    end

    def empty? : Bool
      @current.empty?
    end

    def persist(session : Session) : Nil
      if @next_messages.empty?
        session.delete(KEY)
      else
        session[KEY] = @next_messages.to_json
      end
    end
  end

  module SessionStore
    abstract def load(ctx : Context) : Session?
    abstract def save(ctx : Context, session : Session) : Nil
  end

  # Default store: the whole session lives in an encrypted, signed cookie.
  class CookieSessionStore
    include SessionStore

    MAX_SIZE = 4000

    def initialize(@cookie_name : String, @encryptor : Encryptor, @options : CookieOptions)
    end

    def load(ctx : Context) : Session?
      cookie = ctx.request.cookies[@cookie_name]? || return nil
      json = @encryptor.decrypt?(cookie.value) || return nil
      payload = JSON.parse(json)
      data = {} of String => String
      payload["d"].as_h.each { |k, v| data[k] = v.as_s }
      Session.new(payload["i"].as_s, data)
    rescue
      nil
    end

    def save(ctx : Context, session : Session) : Nil
      if session.destroyed? && session.data.empty?
        ctx.response.cookies << @options.build(@cookie_name, "", expires: Time.unix(0))
        return
      end
      value = @encryptor.encrypt({"i" => session.id, "d" => session.data}.to_json)
      if value.bytesize > MAX_SIZE
        Log.for("silth.session").warn { "Session cookie exceeds #{MAX_SIZE} bytes; consider the cache session store" }
      end
      ctx.response.cookies << @options.build(@cookie_name, value)
    end
  end

  # Server side store backed by `Silth::Cache` — the cookie only holds a signed id.
  class CacheSessionStore
    include SessionStore

    def initialize(@cookie_name : String, @verifier : MessageVerifier, @options : CookieOptions, @ttl : Time::Span)
    end

    def load(ctx : Context) : Session?
      cookie = ctx.request.cookies[@cookie_name]? || return nil
      id = @verifier.verify?(cookie.value) || return nil
      raw = Silth.cache.get("session:#{id}") || return Session.new(id)
      Session.new(id, Hash(String, String).from_json(raw))
    rescue
      nil
    end

    def save(ctx : Context, session : Session) : Nil
      session.previous_id.try { |old| Silth.cache.delete("session:#{old}") }
      Silth.cache.delete("session:#{session.id}") if session.destroyed?
      Silth.cache.set("session:#{session.id}", session.data.to_json, @ttl)
      ctx.response.cookies << @options.build(@cookie_name, @verifier.generate(session.id))
    end
  end

  # Shared cookie attributes.
  struct CookieOptions
    property path : String
    property domain : String?
    property secure : Bool
    property http_only : Bool
    property same_site : HTTP::Cookie::SameSite
    property max_age : Time::Span?

    def initialize(@path = "/", @domain = nil, @secure = false, @http_only = true,
                   @same_site = HTTP::Cookie::SameSite::Lax, @max_age = nil)
    end

    def build(name : String, value : String, expires : Time? = nil) : HTTP::Cookie
      HTTP::Cookie.new(
        name, value,
        path: @path, domain: @domain, secure: @secure, http_only: @http_only,
        samesite: @same_site,
        expires: expires || @max_age.try { |m| Time.utc + m },
      )
    end
  end
end
