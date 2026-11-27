module Silth
  # Password hashing: bcrypt or Argon2id, chosen in `config/auth.yml`, and
  # both always verified, so an application can switch algorithms (or take
  # over another application's users) without resetting passwords.
  #
  # ```yaml
  # # config/auth.yml
  # password_algorithm: argon2id   # bcrypt (default) or argon2id
  # bcrypt_cost: 12
  # argon2:
  #   memory: 19456                # KiB (OWASP: 19 MiB, 2 iterations, 1 lane)
  #   iterations: 2
  #   parallelism: 1
  # ```
  #
  # ```
  # digest = Silth::Password.hash("secret")    # "$2b$12$…" or "$argon2id$v=19$…"
  # Silth::Password.verify("secret", digest)   # => true, whatever the algorithm
  # Silth::Password.needs_rehash?(digest)      # => true when made with other settings
  # ```
  #
  # `Auth::Authenticatable#authenticate?` uses it, and a successful login
  # (`auth.attempt`) re-hashes a password stored with other settings.
  module Password
    # Hashes *plain* with the configured algorithm.
    def self.hash(plain : String) : String
      case algorithm
      when "argon2id"
        Argon2.hash(plain, memory: argon2_memory, iterations: argon2_iterations, parallelism: argon2_parallelism)
      else
        ::Crypto::Bcrypt::Password.create(plain, cost: bcrypt_cost).to_s
      end
    end

    # Checks *plain* against a bcrypt (`$2a$`, `$2b$`, `$2y$`) or Argon2 (`$argon2id$`…) hash.
    def self.verify(plain : String, digest : String) : Bool
      if digest.starts_with?("$argon2")
        Argon2.verify(plain, digest)
      elsif digest.starts_with?("$2")
        ::Crypto::Bcrypt::Password.new(digest).verify(plain)
      else
        false
      end
    rescue
      false
    end

    # True when *digest* was made with another algorithm or other settings than the configured ones.
    def self.needs_rehash?(digest : String) : Bool
      if algorithm == "argon2id"
        return true unless digest.starts_with?("$argon2id$")
        params = Argon2.params(digest)
        params.memory != argon2_memory || params.iterations != argon2_iterations || params.parallelism != argon2_parallelism
      else
        return true unless digest.starts_with?("$2")
        digest.split('$')[2]?.try(&.to_i?) != bcrypt_cost
      end
    rescue
      true
    end

    # `bcrypt` or `argon2id` (`auth.password_algorithm`).
    def self.algorithm : String
      value = Silth.config.string("auth.password_algorithm", "bcrypt").downcase
      value.in?("bcrypt", "argon2id") ? value : raise ConfigError.new("auth.password_algorithm must be bcrypt or argon2id, not #{value}")
    end

    # Tests run with the cheapest settings: hashing dominates factories otherwise.
    private def self.bcrypt_cost : Int32
      Silth.test? ? 4 : Silth.config.int("auth.bcrypt_cost", 12).to_i
    end

    private def self.argon2_memory : Int32
      Silth.test? ? 64 : Silth.config.int("auth.argon2.memory", 19456).to_i
    end

    private def self.argon2_iterations : Int32
      Silth.test? ? 1 : Silth.config.int("auth.argon2.iterations", 2).to_i
    end

    private def self.argon2_parallelism : Int32
      Silth.test? ? 1 : Silth.config.int("auth.argon2.parallelism", 1).to_i
    end
  end
end
