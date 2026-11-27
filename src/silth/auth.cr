module Silth
  # Authentication: session guard, API tokens, remember-me, password resets,
  # email verification, TOTP two-factor and JWT.
  #
  # ```
  # class User < Silth::Model
  #   include Silth::Auth::Authenticatable
  #   primary_key
  #   column email : String
  #   column password_digest : String, hidden: true
  # end
  #
  # # In a controller
  # if auth.attempt(params["email"], params["password"], remember: params.bool("remember"))
  #   redirect session.pull("_intended") || "/dashboard"
  # end
  # auth.logout
  # ```
  module Auth
    Log = ::Log.for("silth.auth")

    SESSION_ID   = "_auth_id"
    SESSION_TYPE = "_auth_type"
    SESSION_HASH = "_auth_hash"
    REMEMBER     = "remember_token"

    # Stores *password* again when its hash was made with other settings than
    # `config/auth.yml` (another algorithm, cost or memory). Called after a
    # successful login; never fails the login.
    def self.rehash(user : Authenticatable, password : String) : Nil
      return unless Silth.config.bool("auth.rehash_on_login", true)
      digest = user.read_attribute("password_digest").as?(String) || return
      return unless Password.needs_rehash?(digest)
      user.password = password
      user.save(validate: false) if user.responds_to?(:save)
    rescue ex
      Log.warn { "Could not re-hash the password of #{user.class.name} #{user.auth_id}: #{ex.message}" }
    end

    # Include in the model representing users.
    module Authenticatable
      # Identifier stored in the session.
      def auth_id : String
        read_attribute(__primary_key_name).to_s
      end

      # Column used to find users by credentials (override for `username`…).
      def self.identifier_column : String
        "email"
      end

      # Hashes with `auth.password_algorithm` (bcrypt or Argon2id, see `Silth::Password`).
      def password=(plain : String) : Nil
        write_attribute("password_digest", Password.hash(plain))
      end

      def authenticate?(plain : String) : Bool
        digest = read_attribute("password_digest").as?(String) || return false
        Crypto.verify_password(plain, digest)
      end

      # Changes when the password changes: invalidates other sessions and reset links.
      def password_fingerprint : String
        Crypto.sha256(read_attribute("password_digest").to_s)[0, 16]
      end

      def email_verified? : Bool
        !read_attribute("email_verified_at").nil?
      end

      # Creates a personal access token and returns its plain text value (shown once).
      def create_token(name : String, abilities : Array(String) = ["*"], expires_in : Time::Span? = nil) : String
        AccessToken.issue(self, name, abilities, expires_in)
      end

      def tokens : ORM::Query(AccessToken)
        AccessToken.where(tokenable_type: self.class.name, tokenable_id: auth_id)
      end
    end

    # Finds a user by id across every model including `Authenticatable`.
    def self.find_user(id : String, type : String? = nil) : Authenticatable?
      {% begin %}
        {% for t in Authenticatable.includers %}
          if type.nil? || type == {{t.name.stringify}}
            if found = {{t}}.find?(id.to_i64? || id)
              return found
            end
          end
        {% end %}
      {% end %}
      nil
    end

    def self.find_by_credentials(login : String, type : String? = nil) : Authenticatable?
      {% begin %}
        {% for t in Authenticatable.includers %}
          if type.nil? || type == {{t.name.stringify}}
            column = Silth.config.string("auth.identifier", "email")
            if found = {{t}}.query.where({column => login.strip.downcase}).first?
              return found
            end
          end
        {% end %}
      {% end %}
      nil
    end

    def self.guard(ctx : Context) : Guard
      Guard.new(ctx)
    end

    # Session based authentication for browsers.
    class Guard
      def initialize(@ctx : Context)
      end

      def user : Authenticatable?
        @ctx.auth_user
      end

      def check? : Bool
        !user.nil?
      end

      def guest? : Bool
        user.nil?
      end

      def id : String?
        user.try(&.auth_id)
      end

      # Validates credentials (rate limited per IP + login) and logs the user in.
      def attempt(login : String?, password : String?, remember : Bool = false) : Bool
        return false if login.nil? || password.nil? || login.empty?
        key = "login:#{@ctx.remote_ip}:#{login.downcase}"
        limit = Silth.config.int("auth.max_attempts", 5)
        if RateLimit.attempts(key, 1.minute) >= limit
          raise TooManyRequests.new(60, "Too many login attempts. Please try again in a minute.")
        end
        user = Auth.find_by_credentials(login)
        if user && user.authenticate?(password)
          RateLimit.clear(key, 1.minute)
          Auth.rehash(user, password)
          login(user, remember)
          Events.dispatch(LoggedIn.new(user.auth_id, user.class.name))
          true
        else
          RateLimit.hit(key, limit, 1.minute)
          Events.dispatch(LoginFailed.new(login, @ctx.remote_ip))
          false
        end
      end

      def login(user : Authenticatable, remember : Bool = false) : Nil
        session = @ctx.session
        session.regenerate
        session[SESSION_ID] = user.auth_id
        session[SESSION_TYPE] = user.class.name
        session[SESSION_HASH] = user.password_fingerprint
        CSRF.rotate(@ctx)
        @ctx.auth_user = user
        if remember
          value = "#{user.class.name}|#{user.auth_id}|#{user.password_fingerprint}"
          @ctx.set_encrypted_cookie(REMEMBER, value, Silth.config.int("auth.remember_days", 30).days)
        end
      end

      def logout : Nil
        if u = user
          Events.dispatch(LoggedOut.new(u.auth_id, u.class.name))
        end
        @ctx.session?.try &.invalidate
        @ctx.delete_cookie(REMEMBER)
        @ctx.auth_user = nil
      end
    end

    # Loads the user from the session (or the remember-me cookie).
    class SessionAuthMiddleware < Middleware
      def call(ctx : Context, chain : Chain) : Nil
        if (session = ctx.session?) && (id = session[SESSION_ID]?)
          user = Auth.find_user(id, session[SESSION_TYPE]?)
          if user && session[SESSION_HASH]? == user.password_fingerprint
            ctx.auth_user = user
          else
            session.delete(SESSION_ID)
          end
        elsif value = ctx.encrypted_cookie(REMEMBER)
          type, id, fingerprint = value.split('|', 3) + ["", "", ""]
          if (user = Auth.find_user(id, type)) && user.password_fingerprint == fingerprint
            Guard.new(ctx).login(user, remember: true)
          end
        end
        chain.next(ctx)
      end
    end

    # Authenticates `Authorization: Bearer <token>` with personal access tokens or JWTs.
    class TokenAuthMiddleware < Middleware
      def call(ctx : Context, chain : Chain) : Nil
        if (header = ctx.header("Authorization")) && header.starts_with?("Bearer ")
          raw = header.lchop("Bearer ").strip
          if raw.count('.') == 2 && (secret = Silth.config.string?("auth.jwt_secret"))
            if (claims = JWT.decode?(raw, secret)) && (subject = claims["sub"]?)
              ctx.auth_user = Auth.find_user(subject.to_s, claims["typ"]?.try(&.as_s?))
            end
          elsif token = AccessToken.find_valid(raw)
            ctx.auth_token = token
            ctx.auth_user = Auth.find_user(token.tokenable_id, token.tokenable_type)
            token.mark_used
          end
        end
        chain.next(ctx)
      end
    end

    # `middleware: [:auth]` — requires an authenticated user.
    class Authenticate < Middleware
      def call(ctx : Context, chain : Chain) : Nil
        if ctx.auth_user
          chain.next(ctx)
        elsif ctx.wants_json? || ctx.session?.nil?
          raise Unauthorized.new
        else
          ctx.session["_intended"] = ctx.request.resource if ctx.get?
          ctx.redirect(Silth.config.string("auth.login_path", "/login"))
        end
      end
    end

    # `middleware: [:guest]` — redirects authenticated users away (login/register pages).
    class RedirectIfAuthenticated < Middleware
      def call(ctx : Context, chain : Chain) : Nil
        if ctx.auth_user
          ctx.redirect(Silth.config.string("auth.home_path", "/"))
        else
          chain.next(ctx)
        end
      end
    end

    # `middleware: [:verified]` — requires a verified email address.
    class EnsureEmailVerified < Middleware
      def call(ctx : Context, chain : Chain) : Nil
        user = ctx.auth_user
        if user && !user.email_verified?
          raise Forbidden.new("Your email address is not verified.") if ctx.wants_json?
          ctx.redirect(Silth.config.string("auth.verify_path", "/email/verify"))
        else
          chain.next(ctx)
        end
      end
    end

    # --- events -----------------------------------------------------------------

    class LoggedIn < Event
      getter user_id : String
      getter user_type : String

      def initialize(@user_id, @user_type)
      end
    end

    class LoggedOut < Event
      getter user_id : String
      getter user_type : String

      def initialize(@user_id, @user_type)
      end
    end

    class LoginFailed < Event
      getter login : String
      getter ip : String

      def initialize(@login, @ip)
      end
    end

    # --- password reset & email verification (stateless, signed) -------------

    def self.password_reset_token(user : Authenticatable, expires_in : Time::Span = 1.hour) : String
      Silth.verifier("password_reset").generate("#{user.class.name}|#{user.auth_id}|#{user.password_fingerprint}", expires_in)
    end

    # Returns the user if the token is valid and the password did not change since.
    def self.verify_password_reset(token : String) : Authenticatable?
      value = Silth.verifier("password_reset").verify?(token) || return nil
      type, id, fingerprint = value.split('|', 3)
      user = find_user(id, type) || return nil
      user.password_fingerprint == fingerprint ? user : nil
    end

    def self.verification_url(user : Authenticatable, expires_in : Time::Span = 24.hours, path : String = "/email/verify") : String
      SignedURL.sign("#{path}/#{user.auth_id}", expires_in, Silth.config.string("app.url", ""))
    end

    # --- personal access tokens ---------------------------------------------------

    class AccessToken < Model
      table silth_access_tokens

      primary_key
      column tokenable_type : String
      column tokenable_id : String
      column name : String
      column token_hash : String, hidden: true
      column abilities : String = "*"
      column last_used_at : Time?
      column expires_at : Time?
      timestamps

      def self.issue(user : Authenticatable, name : String, abilities : Array(String), expires_in : Time::Span?) : String
        secret = Crypto.token(30)
        token = create!(tokenable_type: user.class.name, tokenable_id: user.auth_id, name: name,
          token_hash: Crypto.sha256(secret), abilities: abilities.join(','), expires_at: expires_in.try { |e| Time.utc + e })
        "#{token.id}|#{secret}"
      end

      def self.find_valid(raw : String) : AccessToken?
        id, _, secret = raw.partition('|')
        return nil if secret.empty?
        token = find?(id.to_i64? || return nil) || return nil
        return nil unless Crypto.secure_compare(token.token_hash, Crypto.sha256(secret))
        return nil if (exp = token.expires_at) && exp < Time.utc
        token
      end

      def can?(ability : String) : Bool
        list = abilities.split(',')
        list.includes?("*") || list.includes?(ability) || list.any? { |a| a.ends_with?(":*") && ability.starts_with?(a.rchop('*')) }
      end

      def mark_used : Nil
        return if (last = last_used_at) && last > Time.utc - 1.minute
        self.last_used_at = Time.utc
        save(validate: false)
      end
    end

    # --- TOTP (RFC 6238) for two-factor authentication -----------------------------

    module TOTP
      ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

      def self.generate_secret(bytes : Int32 = 20) : String
        base32_encode(Random::Secure.random_bytes(bytes))
      end

      def self.code(secret : String, time : Time = Time.utc, step : Int32 = 30, digits : Int32 = 6) : String
        counter = time.to_unix // step
        msg = Bytes.new(8)
        8.times { |i| msg[7 - i] = ((counter >> (8 * i)) & 0xff).to_u8 }
        hmac = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA1, base32_decode(secret), msg)
        offset = hmac[-1] & 0x0f
        binary = ((hmac[offset].to_i & 0x7f) << 24) | (hmac[offset + 1].to_i << 16) | (hmac[offset + 2].to_i << 8) | hmac[offset + 3].to_i
        (binary % (10 ** digits)).to_s.rjust(digits, '0')
      end

      def self.verify(secret : String, code : String, drift : Int32 = 1, time : Time = Time.utc) : Bool
        (-drift..drift).any? { |d| Crypto.secure_compare(code(secret, time + (d * 30).seconds), code.strip) }
      end

      def self.provisioning_uri(secret : String, account : String, issuer : String) : String
        "otpauth://totp/#{URI.encode_path_segment(issuer)}:#{URI.encode_path_segment(account)}?secret=#{secret}&issuer=#{URI.encode_www_form(issuer)}"
      end

      def self.base32_encode(data : Bytes) : String
        String.build do |io|
          buffer = 0
          bits = 0
          data.each do |byte|
            buffer = (buffer << 8) | byte
            bits += 8
            while bits >= 5
              io << ALPHABET[(buffer >> (bits - 5)) & 31]
              bits -= 5
            end
          end
          io << ALPHABET[(buffer << (5 - bits)) & 31] if bits > 0
        end
      end

      def self.base32_decode(text : String) : Bytes
        clean = text.upcase.delete("= ")
        io = IO::Memory.new
        buffer = 0
        bits = 0
        clean.each_char do |c|
          idx = ALPHABET.index(c) || next
          buffer = (buffer << 5) | idx
          bits += 5
          if bits >= 8
            io.write_byte(((buffer >> (bits - 8)) & 0xff).to_u8)
            bits -= 8
          end
        end
        io.to_slice
      end
    end
  end

  # Compact JSON Web Tokens signed with HMAC: HS256 (default), HS384 or HS512.
  #
  # ```
  # token = Silth::JWT.encode({"sub" => user.auth_id}, secret, expires_in: 1.hour)
  # token = Silth::JWT.encode(claims, secret, algorithm: "HS512")
  # claims = Silth::JWT.decode(token, secret)                        # raises Silth::JWT::Invalid
  # claims = Silth::JWT.decode(token, secret, algorithms: ["HS512"]) # only accept HS512
  # ```
  #
  # `auth.jwt_algorithm` in `config/auth.yml` sets the default algorithm for
  # `encode`. `decode` accepts the three HMAC algorithms unless told otherwise,
  # and never `none`.
  module JWT
    class Invalid < Silth::Error; end

    ALGORITHMS = {
      "HS256" => OpenSSL::Algorithm::SHA256,
      "HS384" => OpenSSL::Algorithm::SHA384,
      "HS512" => OpenSSL::Algorithm::SHA512,
    }

    def self.default_algorithm : String
      Silth.config.string("auth.jwt_algorithm", "HS256").upcase
    end

    def self.encode(claims : Hash(String, _), secret : String, expires_in : Time::Span? = nil, algorithm : String = default_algorithm) : String
      digest = ALGORITHMS[algorithm]? || raise ArgumentError.new("Unsupported JWT algorithm #{algorithm} (use #{ALGORITHMS.keys.join(", ")})")
      payload = JSON.parse(claims.to_json).as_h
      now = Time.utc.to_unix
      payload["iat"] ||= JSON::Any.new(now)
      payload["exp"] = JSON::Any.new(now + expires_in.total_seconds.to_i64) if expires_in
      header = b64(%({"alg":"#{algorithm}","typ":"JWT"}))
      body = b64(payload.to_json)
      "#{header}.#{body}.#{sign(digest, secret, "#{header}.#{body}")}"
    end

    def self.decode(token : String, secret : String, leeway : Int32 = 30, algorithms : Array(String) = ALGORITHMS.keys) : Hash(String, JSON::Any)
      parts = token.split('.')
      raise Invalid.new("Malformed token") unless parts.size == 3
      header = JSON.parse(String.new(Base64.decode(parts[0])))
      algorithm = header["alg"]?.try(&.as_s?) || ""
      digest = ALGORITHMS[algorithm]?
      raise Invalid.new("Unsupported algorithm") unless digest && algorithms.includes?(algorithm)
      expected = sign(digest, secret, "#{parts[0]}.#{parts[1]}")
      raise Invalid.new("Bad signature") unless Crypto.secure_compare(expected, parts[2])
      claims = JSON.parse(String.new(Base64.decode(parts[1]))).as_h
      now = Time.utc.to_unix
      if (exp = claims["exp"]?.try(&.as_i64?)) && now > exp + leeway
        raise Invalid.new("Token expired")
      end
      if (nbf = claims["nbf"]?.try(&.as_i64?)) && now + leeway < nbf
        raise Invalid.new("Token not yet valid")
      end
      claims
    rescue ex : JSON::ParseException | Base64::Error
      raise Invalid.new("Malformed token: #{ex.message}")
    end

    private def self.sign(digest : OpenSSL::Algorithm, secret : String, data : String) : String
      Base64.urlsafe_encode(OpenSSL::HMAC.digest(digest, secret, data), padding: false)
    end

    def self.decode?(token : String, secret : String) : Hash(String, JSON::Any)?
      decode(token, secret)
    rescue Invalid
      nil
    end

    private def self.b64(text : String) : String
      Base64.urlsafe_encode(text, padding: false)
    end
  end
end
