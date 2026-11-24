module Silth
  @@config : Config?
  @@app : App?
  @@assets : Assets?
  @@verifiers = {} of String => MessageVerifier
  @@encryptors = {} of String => Encryptor
  @@session_store : SessionStore?
  @@app_key : Bytes?
  class_getter health_checks = {} of String => Proc(Bool)

  # Current environment: `SILTH_ENV`, then `APP_ENV`, defaults to development.
  def self.env : String
    ENV["SILTH_ENV"]? || ENV["APP_ENV"]? || "development"
  end

  def self.env=(value : String) : Nil
    ENV["SILTH_ENV"] = value
  end

  def self.development? : Bool
    env == "development"
  end

  def self.production? : Bool
    env == "production"
  end

  def self.test? : Bool
    env == "test"
  end

  def self.root : String
    Dir.current
  end

  def self.config : Config
    @@config ||= load_config
  end

  def self.config=(config : Config) : Nil
    @@config = config
  end

  def self.load_config(dir : String = "config") : Config
    Dotenv.load(Dir.current, env)
    @@config = Config.load(dir, env)
  end

  def self.app : App
    @@app ||= App.new
  end

  def self.app=(app : App) : Nil
    @@app = app
  end

  def self.router : Router
    app.router
  end

  def self.configure(&block : App -> Nil) : Nil
    app.configure(&block)
  end

  def self.boot : App
    app.boot
  end

  def self.serve(host : String? = nil, port : Int32? = nil) : Nil
    app.serve(host, port)
  end

  def self.assets : Assets
    @@assets ||= Assets.new(config.string("assets.source", "assets"), config.string("assets.output", "public/assets"), config.string("assets.prefix", "/assets"))
  end

  # Application secret (`APP_KEY`). Generate one with `silth key:generate`.
  def self.app_key : Bytes
    @@app_key ||= begin
      key = ENV["APP_KEY"]? || config.string?("app.key")
      if key.nil? || key.empty?
        raise ConfigError.new("APP_KEY is not set. Run `silth key:generate`.") if production?
        ::Log.for("silth").warn { "APP_KEY is not set; using an ephemeral development key" } unless test?
        Random::Secure.random_bytes(32)
      else
        Crypto.decode_app_key(key)
      end
    end
  end

  def self.app_key=(key : String) : Nil
    @@app_key = Crypto.decode_app_key(key)
    @@verifiers.clear
    @@encryptors.clear
  end

  def self.verifier(purpose : String = "default") : MessageVerifier
    @@verifiers[purpose] ||= MessageVerifier.new(app_key, purpose)
  end

  def self.encryptor(purpose : String = "default") : Encryptor
    @@encryptors[purpose] ||= Encryptor.new(app_key, purpose)
  end

  def self.encrypt(value : String) : String
    encryptor.encrypt(value)
  end

  def self.decrypt(value : String) : String
    encryptor.decrypt(value)
  end

  def self.session_store : SessionStore
    @@session_store ||= begin
      name = config.string("session.cookie", "_silth_session")
      options = CookieOptions.new(
        secure: config.bool("session.secure", production?),
        same_site: HTTP::Cookie::SameSite.parse?(config.string("session.same_site", "lax")) || HTTP::Cookie::SameSite::Lax,
        max_age: config.int?("session.lifetime").try(&.minutes),
      )
      if config.string("session.driver", "cookie") == "cache"
        CacheSessionStore.new(name, verifier("session"), options, config.int("session.lifetime", 120).minutes)
      else
        CookieSessionStore.new(name, encryptor("session"), options)
      end
    end
  end

  def self.session_store=(store : SessionStore) : Nil
    @@session_store = store
  end

  # Registers a check reported by `GET /up`.
  def self.health_check(name : String, &block : -> Bool) : Nil
    @@health_checks[name] = block
  end

  # :nodoc:
  def self.boot_subsystems : Nil
    DB.boot
    if config.string("realtime.pubsub", "memory") == "redis"
      PubSub.boot_redis(config.string("realtime.redis_url", ENV["REDIS_URL"]? || "redis://localhost:6379/0"))
    end
    Telemetry.boot
    Profiler.boot
    Events.boot
  end

  # Resets global state (used by the test helpers).
  def self.reset! : Nil
    @@app = nil
    @@config = nil
    @@assets = nil
    @@session_store = nil
    Routes.sets.clear
  end
end
