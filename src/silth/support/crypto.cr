require "openssl"
require "openssl/hmac"
require "base64"
require "random/secure"
require "crypto/subtle"
require "crypto/bcrypt/password"
require "digest/sha256"
require "json"
require "uuid"

module Silth
  # Cryptographic helpers built on Crystal's std (OpenSSL bindings).
  module Crypto
    extend self

    class InvalidMessage < Exception; end

    # URL-safe random token (`bytes` of entropy).
    def token(bytes : Int32 = 32) : String
      Base64.urlsafe_encode(Random::Secure.random_bytes(bytes), padding: false)
    end

    def hex_token(bytes : Int32 = 16) : String
      Random::Secure.hex(bytes)
    end

    def uuid : String
      UUID.v4.to_s
    end

    # UUIDv7: time ordered, ideal for primary keys and logs.
    def uuid7 : String
      ms = Time.utc.to_unix_ms
      bytes = Random::Secure.random_bytes(16)
      6.times { |i| bytes[i] = ((ms >> (8 * (5 - i))) & 0xff).to_u8 }
      bytes[6] = (bytes[6] & 0x0f) | 0x70
      bytes[8] = (bytes[8] & 0x3f) | 0x80
      hex = bytes.hexstring
      "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
    end

    def secure_compare(a : String | Bytes, b : String | Bytes) : Bool
      ::Crypto::Subtle.constant_time_compare(a.to_slice, b.to_slice)
    end

    def sha256(data : String | Bytes) : String
      Digest::SHA256.hexdigest(data)
    end

    def hmac(key : String | Bytes, data : String | Bytes) : Bytes
      OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, key, data)
    end

    def hmac_hex(key : String | Bytes, data : String | Bytes) : String
      OpenSSL::HMAC.hexdigest(OpenSSL::Algorithm::SHA256, key, data)
    end

    # Derives a purpose specific 32 bytes key from the application secret.
    def derive_key(secret : String | Bytes, purpose : String, size : Int32 = 32) : Bytes
      OpenSSL::PKCS5.pbkdf2_hmac(secret, "silth:#{purpose}", iterations: 1000, algorithm: OpenSSL::Algorithm::SHA256, key_size: size)
    end

    # Password hashing (bcrypt).
    def hash_password(password : String, cost : Int32 = 12) : String
      ::Crypto::Bcrypt::Password.create(password, cost: cost).to_s
    end

    def verify_password(password : String, digest : String) : Bool
      ::Crypto::Bcrypt::Password.new(digest).verify(password)
    rescue
      false
    end

    # Generates a fresh application key (`APP_KEY`).
    def generate_app_key : String
      "base64:" + Base64.strict_encode(Random::Secure.random_bytes(32))
    end

    def decode_app_key(key : String) : Bytes
      if key.starts_with?("base64:")
        Base64.decode(key.lchop("base64:"))
      else
        key.to_slice
      end
    end
  end

  # Signs (but does not encrypt) messages: `payload--signature`.
  # Supports purposes and expiration.
  class MessageVerifier
    def initialize(secret : String | Bytes, purpose : String = "default")
      @key = Crypto.derive_key(secret, "verifier:#{purpose}")
    end

    def generate(value : String, expires_in : Time::Span? = nil, purpose : String? = nil) : String
      envelope = {
        "v" => JSON::Any.new(value),
        "e" => JSON::Any.new(expires_in.try { |s| (Time.utc + s).to_unix } || 0_i64),
        "p" => JSON::Any.new(purpose || ""),
      }
      data = Base64.urlsafe_encode(envelope.to_json, padding: false)
      "#{data}--#{Crypto.hmac_hex(@key, data)}"
    end

    def verify?(message : String, purpose : String? = nil) : String?
      data, _, digest = message.rpartition("--")
      return nil if data.empty? || digest.empty?
      return nil unless Crypto.secure_compare(Crypto.hmac_hex(@key, data), digest)
      envelope = JSON.parse(String.new(Base64.decode(data)))
      exp = envelope["e"].as_i64
      return nil if exp > 0 && Time.utc.to_unix > exp
      return nil if (envelope["p"].as_s? || "") != (purpose || "")
      envelope["v"].as_s
    rescue
      nil
    end

    def verify(message : String, purpose : String? = nil) : String
      verify?(message, purpose) || raise Crypto::InvalidMessage.new("Invalid or expired signed message")
    end
  end

  # Authenticated encryption (AES-256-CBC + HMAC-SHA256, encrypt-then-MAC).
  class Encryptor
    def initialize(secret : String | Bytes, purpose : String = "default")
      @enc_key = Crypto.derive_key(secret, "enc:#{purpose}")
      @mac_key = Crypto.derive_key(secret, "mac:#{purpose}")
    end

    def encrypt(plain : String) : String
      cipher = OpenSSL::Cipher.new("aes-256-cbc")
      cipher.encrypt
      cipher.key = @enc_key
      iv = cipher.random_iv
      io = IO::Memory.new
      io.write(cipher.update(plain.to_slice))
      io.write(cipher.final)
      body = Base64.urlsafe_encode(iv, padding: false) + "." + Base64.urlsafe_encode(io.to_slice, padding: false)
      "#{body}.#{Base64.urlsafe_encode(Crypto.hmac(@mac_key, body), padding: false)}"
    end

    def decrypt?(token : String) : String?
      parts = token.split('.')
      return nil unless parts.size == 3
      body = "#{parts[0]}.#{parts[1]}"
      expected = Base64.urlsafe_encode(Crypto.hmac(@mac_key, body), padding: false)
      return nil unless Crypto.secure_compare(expected, parts[2])
      cipher = OpenSSL::Cipher.new("aes-256-cbc")
      cipher.decrypt
      cipher.key = @enc_key
      cipher.iv = Base64.decode(parts[0])
      io = IO::Memory.new
      io.write(cipher.update(Base64.decode(parts[1])))
      io.write(cipher.final)
      String.new(io.to_slice)
    rescue
      nil
    end

    def decrypt(token : String) : String
      decrypt?(token) || raise Crypto::InvalidMessage.new("Unable to decrypt payload")
    end
  end
end
