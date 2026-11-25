require "openssl"
require "base64"

module Silth::DB::MySQL
  # RSA encryption of the password for `caching_sha2_password` and `sha256_password`
  # full authentication on connections without TLS.
  #
  # The password (NUL terminated) is XOR-ed with the 20 byte handshake scramble, then
  # encrypted with the server's public key using RSA-OAEP, as libmysqlclient does.
  #
  # ```
  # pem = File.read("/var/lib/mysql/public_key.pem")
  # MySQL::RSA.encrypt_password("secret", scramble, pem) # => Bytes (256 bytes for a 2048-bit key)
  # ```
  module RSA
    # Minimal libcrypto (OpenSSL 1.1 / 3.x) bindings: the stdlib does not expose RSA.
    # Symbols already bound by the stdlib (such as BIO_free) are avoided on purpose.
    @[Link("crypto")]
    lib LibPKey
      type EVP_PKEY = Void*
      type EVP_PKEY_CTX = Void*

      EVP_PKEY_RSA              =    6
      EVP_PKEY_CTRL_RSA_PADDING = 4097 # EVP_PKEY_ALG_CTRL + 1
      RSA_PKCS1_OAEP_PADDING    =    4

      fun err_clear_error = ERR_clear_error
      fun d2i_pubkey = d2i_PUBKEY(key : EVP_PKEY*, der : UInt8**, length : LibC::Long) : EVP_PKEY
      fun d2i_public_key = d2i_PublicKey(type : Int32, key : EVP_PKEY*, der : UInt8**, length : LibC::Long) : EVP_PKEY
      fun evp_pkey_free = EVP_PKEY_free(key : EVP_PKEY)
      fun evp_pkey_ctx_new = EVP_PKEY_CTX_new(key : EVP_PKEY, engine : Void*) : EVP_PKEY_CTX
      fun evp_pkey_ctx_free = EVP_PKEY_CTX_free(ctx : EVP_PKEY_CTX)
      fun evp_pkey_encrypt_init = EVP_PKEY_encrypt_init(ctx : EVP_PKEY_CTX) : Int32
      fun evp_pkey_ctx_ctrl = EVP_PKEY_CTX_ctrl(ctx : EVP_PKEY_CTX, keytype : Int32, optype : Int32, cmd : Int32, p1 : Int32, p2 : Void*) : Int32
      fun evp_pkey_encrypt = EVP_PKEY_encrypt(ctx : EVP_PKEY_CTX, dst : UInt8*, dst_len : LibC::SizeT*, src : UInt8*, src_len : LibC::SizeT) : Int32
    end

    PEM = /-----BEGIN (RSA )?PUBLIC KEY-----(.+?)-----END (?:RSA )?PUBLIC KEY-----/m

    # Obfuscates `password + "\0"` with *scramble* and encrypts it with *public_key_pem*.
    def self.encrypt_password(password : String, scramble : Bytes, public_key_pem : String) : Bytes
      raise ConnectionError.new("MySQL RSA authentication: empty scramble") if scramble.empty?
      plain = (password + "\0").to_slice
      obfuscated = Bytes.new(plain.size) { |i| plain[i] ^ scramble[i % scramble.size] }
      encrypt(obfuscated, public_key_pem)
    end

    # Encrypts *data* with an RSA public key in PEM format, OAEP padding.
    # Accepts `BEGIN PUBLIC KEY` (what MySQL sends) and `BEGIN RSA PUBLIC KEY`.
    def self.encrypt(data : Bytes, public_key_pem : String) : Bytes
      key = read_public_key(public_key_pem)
      ctx = LibPKey.evp_pkey_ctx_new(key, nil)
      begin
        raise ConnectionError.new("MySQL RSA authentication: cannot create an encryption context") if ctx.null?
        check LibPKey.evp_pkey_encrypt_init(ctx), "init"
        check LibPKey.evp_pkey_ctx_ctrl(ctx, LibPKey::EVP_PKEY_RSA, -1, LibPKey::EVP_PKEY_CTRL_RSA_PADDING, LibPKey::RSA_PKCS1_OAEP_PADDING, nil), "OAEP padding"
        size = LibC::SizeT.new(0)
        check LibPKey.evp_pkey_encrypt(ctx, nil, pointerof(size), data.to_unsafe, LibC::SizeT.new(data.size)), "size"
        output = Bytes.new(size)
        check LibPKey.evp_pkey_encrypt(ctx, output.to_unsafe, pointerof(size), data.to_unsafe, LibC::SizeT.new(data.size)),
          "encryption, is the password longer than the key allows?"
        output[0, size]
      ensure
        LibPKey.evp_pkey_ctx_free(ctx) unless ctx.null?
        LibPKey.evp_pkey_free(key)
      end
    end

    private def self.read_public_key(pem : String) : LibPKey::EVP_PKEY
      match = PEM.match(pem) || raise ConnectionError.new("MySQL RSA authentication: the server public key is not a PEM public key")
      der = Base64.decode(match[2].gsub(/\s+/, ""))
      cursor = der.to_unsafe
      key = if match[1]?
              LibPKey.d2i_public_key(LibPKey::EVP_PKEY_RSA, nil, pointerof(cursor), der.size)
            else
              LibPKey.d2i_pubkey(nil, pointerof(cursor), der.size)
            end
      if key.null?
        LibPKey.err_clear_error
        raise ConnectionError.new("MySQL RSA authentication: invalid server public key")
      end
      key
    rescue ex : Base64::Error
      raise ConnectionError.new("MySQL RSA authentication: invalid server public key (#{ex.message})")
    end

    private def self.check(status : Int32, step : String) : Nil
      return if status > 0
      LibPKey.err_clear_error
      raise ConnectionError.new("MySQL RSA authentication failed (#{step})")
    end
  end
end
