require "base64"

module Silth
  # BLAKE2b (RFC 7693): the hash inside Argon2. Variable output length (1 to 64 bytes).
  #
  # ```
  # Silth::Blake2b.digest("abc".to_slice).hexstring # => "ba80a53f981c4d0d…" (64 bytes)
  # Silth::Blake2b.digest("abc".to_slice, 32)       # 32 bytes
  # ```
  class Blake2b
    IV = StaticArray[
      0x6a09e667f3bcc908_u64, 0xbb67ae8584caa73b_u64, 0x3c6ef372fe94f82b_u64, 0xa54ff53a5f1d36f1_u64,
      0x510e527fade682d1_u64, 0x9b05688c2b3e6c1f_u64, 0x1f83d9abfb41bd6b_u64, 0x5be0cd19137e2179_u64,
    ]

    SIGMA = StaticArray[
      StaticArray[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
      StaticArray[14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
      StaticArray[11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
      StaticArray[7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
      StaticArray[9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
      StaticArray[2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
      StaticArray[12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
      StaticArray[13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
      StaticArray[6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
      StaticArray[10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
      StaticArray[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
      StaticArray[14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    ]

    @h = StaticArray(UInt64, 8).new(0_u64)
    @buffer = Bytes.new(128)
    @filled = 0
    @counter = 0_u128

    def initialize(@size : Int32 = 64)
      raise ArgumentError.new("BLAKE2b output is 1 to 64 bytes") unless 1 <= @size <= 64
      8.times { |i| @h[i] = IV[i] }
      @h[0] ^= 0x01010000_u64 ^ @size.to_u64
    end

    def self.digest(data : Bytes, size : Int32 = 64) : Bytes
      new(size).update(data).final
    end

    def update(data : Bytes) : self
      offset = 0
      while offset < data.size
        if @filled == 128 # keep the last block for `final`
          @counter &+= 128
          compress(@buffer, false)
          @filled = 0
        end
        take = Math.min(128 - @filled, data.size - offset)
        data[offset, take].copy_to(@buffer + @filled)
        @filled += take
        offset += take
      end
      self
    end

    def final : Bytes
      @counter &+= @filled
      (@buffer + @filled).fill(0_u8)
      compress(@buffer, true)
      result = Bytes.new(64)
      8.times { |i| IO::ByteFormat::LittleEndian.encode(@h[i], result + i * 8) }
      result[0, @size]
    end

    private def compress(block : Bytes, last : Bool) : Nil
      m = StaticArray(UInt64, 16).new { |i| IO::ByteFormat::LittleEndian.decode(UInt64, block + i * 8) }
      work = StaticArray(UInt64, 16).new(0_u64)
      v = work.to_unsafe
      8.times { |i| v[i] = @h[i]; v[i + 8] = IV[i] }
      v[12] ^= @counter.to_u64!
      v[13] ^= (@counter >> 64).to_u64!
      v[14] = ~v[14] if last
      12.times do |round|
        s = SIGMA[round]
        mix(v, 0, 4, 8, 12, m[s[0]], m[s[1]])
        mix(v, 1, 5, 9, 13, m[s[2]], m[s[3]])
        mix(v, 2, 6, 10, 14, m[s[4]], m[s[5]])
        mix(v, 3, 7, 11, 15, m[s[6]], m[s[7]])
        mix(v, 0, 5, 10, 15, m[s[8]], m[s[9]])
        mix(v, 1, 6, 11, 12, m[s[10]], m[s[11]])
        mix(v, 2, 7, 8, 13, m[s[12]], m[s[13]])
        mix(v, 3, 4, 9, 14, m[s[14]], m[s[15]])
      end
      8.times { |i| @h[i] ^= v[i] ^ v[i + 8] }
    end

    @[AlwaysInline]
    private def mix(v : Pointer(UInt64), a, b, c, d, x : UInt64, y : UInt64) : Nil
      v[a] = v[a] &+ v[b] &+ x
      v[d] = (v[d] ^ v[a]).rotate_right(32)
      v[c] = v[c] &+ v[d]
      v[b] = (v[b] ^ v[c]).rotate_right(24)
      v[a] = v[a] &+ v[b] &+ y
      v[d] = (v[d] ^ v[a]).rotate_right(16)
      v[c] = v[c] &+ v[d]
      v[b] = (v[b] ^ v[c]).rotate_right(63)
    end
  end

  # Argon2id password hashing (RFC 9106), the algorithm OWASP recommends, in
  # pure Crystal. Hashes use the PHC string format shared by every
  # implementation (`$argon2id$v=19$m=19456,t=2,p=1$<salt>$<hash>`), so hashes
  # made by Rust's `argon2`, PHP's `password_hash` or libsodium verify here.
  #
  # ```
  # digest = Silth::Argon2.hash("secret")  # m=19456 KiB, t=2, p=1 (OWASP)
  # Silth::Argon2.verify("secret", digest) # => true
  # Silth::Argon2.hash("secret", memory: 65536, iterations: 3, parallelism: 4)
  # ```
  #
  # Most apps go through `Silth::Password`, which picks bcrypt or Argon2id
  # from the configuration and recognizes both.
  module Argon2
    VERSION     = 0x13
    BLOCK_WORDS =  128 # 1 KiB blocks of 64-bit words
    SYNC_POINTS =    4

    enum Type
      D  = 0
      I  = 1
      ID = 2
    end

    record Params, memory : Int32 = 19456, iterations : Int32 = 2, parallelism : Int32 = 1, length : Int32 = 32, type : Type = Type::ID

    class Error < Silth::Error; end

    # Hashes *password* with a fresh 16-byte salt; returns the PHC string.
    def self.hash(password : String, memory : Int32 = 19456, iterations : Int32 = 2, parallelism : Int32 = 1, length : Int32 = 32) : String
      params = Params.new(memory, iterations, parallelism, length)
      salt = Random::Secure.random_bytes(16)
      encode(params, salt, derive(password.to_slice, salt, params))
    end

    # Checks *password* against a PHC string (`$argon2id$…`, `$argon2i$…` or `$argon2d$…`).
    def self.verify(password : String, digest : String) : Bool
      params, salt, expected = decode(digest)
      actual = derive(password.to_slice, salt, params)
      Crypto.secure_compare(actual, expected)
    rescue Error
      false
    end

    # The parameters of a PHC string.
    def self.params(digest : String) : Params
      decode(digest)[0]
    end

    def self.encode(params : Params, salt : Bytes, tag : Bytes) : String
      type = params.type.to_s.downcase
      "$argon2#{type}$v=#{VERSION}$m=#{params.memory},t=#{params.iterations},p=#{params.parallelism}$#{b64(salt)}$#{b64(tag)}"
    end

    def self.decode(digest : String) : {Params, Bytes, Bytes}
      parts = digest.split('$')
      raise Error.new("Not an Argon2 hash") unless parts.size == 6 && parts[0].empty?
      type = case parts[1]
             when "argon2id" then Type::ID
             when "argon2i"  then Type::I
             when "argon2d"  then Type::D
             else                 raise Error.new("Not an Argon2 hash")
             end
      raise Error.new("Unsupported Argon2 version #{parts[2]}") unless parts[2] == "v=19"
      settings = parts[3].split(',').to_h { |kv| {kv[0, 1], kv[2..].to_i? || raise Error.new("Invalid parameters")} }
      salt = unb64(parts[4])
      tag = unb64(parts[5])
      params = Params.new(settings["m"]? || 0, settings["t"]? || 0, settings["p"]? || 0, tag.size, type)
      {params, salt, tag}
    end

    # The raw tag (RFC 9106 section 3), with an optional *secret* key and *data*.
    def self.derive(password : Bytes, salt : Bytes, params : Params, secret : Bytes = Bytes.empty, data : Bytes = Bytes.empty) : Bytes
      lanes = params.parallelism
      raise Error.new("Invalid Argon2 parameters") unless 1 <= lanes <= 0xFFFFFF && params.iterations >= 1 && params.memory >= 8 * lanes && params.length >= 4 && salt.size >= 8
      raise Error.new("Argon2 memory above 4 GiB") if params.memory > 4 * 1024 * 1024

      h0 = Blake2b.new(64)
      {lanes, params.length, params.memory, params.iterations, VERSION, params.type.value}.each { |n| h0.update(le32(n)) }
      {password, salt, secret, data}.each do |bytes|
        h0.update(le32(bytes.size))
        h0.update(bytes)
      end
      seed = Bytes.new(72)
      h0.final.copy_to(seed)

      segment_length = params.memory // (lanes * SYNC_POINTS)
      lane_length = segment_length * SYNC_POINTS
      blocks = lane_length * lanes
      memory = Slice(UInt64).new(blocks * BLOCK_WORDS, 0_u64)

      lanes.times do |lane|
        2.times do |i|
          IO::ByteFormat::LittleEndian.encode(i.to_u32, seed + 64)
          IO::ByteFormat::LittleEndian.encode(lane.to_u32, seed + 68)
          load_block(memory + (lane * lane_length + i) * BLOCK_WORDS, variable_hash(seed, 1024))
        end
      end

      filler = Filler.new(memory, lanes, lane_length, segment_length, blocks, params)
      params.iterations.times do |pass|
        SYNC_POINTS.times do |slice|
          lanes.times { |lane| filler.fill_segment(pass, lane, slice) }
        end
      end

      final = Slice(UInt64).new(BLOCK_WORDS) { |w| memory[(lane_length - 1) * BLOCK_WORDS + w] }
      (1...lanes).each do |lane|
        last = (lane * lane_length + lane_length - 1) * BLOCK_WORDS
        BLOCK_WORDS.times { |w| final[w] ^= memory[last + w] }
      end
      bytes = Bytes.new(1024)
      BLOCK_WORDS.times { |w| IO::ByteFormat::LittleEndian.encode(final[w], bytes + w * 8) }
      variable_hash(bytes, params.length)
    end

    # H' (RFC 9106 section 3.3): BLAKE2b extended to any output length.
    def self.variable_hash(input : Bytes, length : Int32) : Bytes
      if length <= 64
        return Blake2b.new(length).update(le32(length)).update(input).final
      end
      result = Bytes.new(length)
      v = Blake2b.new(64).update(le32(length)).update(input).final
      v[0, 32].copy_to(result)
      offset = 32
      while length - offset > 64
        v = Blake2b.digest(v, 64)
        v[0, 32].copy_to(result + offset)
        offset += 32
      end
      Blake2b.digest(v, length - offset).copy_to(result + offset)
      result
    end

    private def self.load_block(target : Slice(UInt64), bytes : Bytes) : Nil
      BLOCK_WORDS.times { |w| target[w] = IO::ByteFormat::LittleEndian.decode(UInt64, bytes + w * 8) }
    end

    private def self.le32(n : Int) : Bytes
      bytes = Bytes.new(4)
      IO::ByteFormat::LittleEndian.encode(n.to_u32, bytes)
      bytes
    end

    private def self.b64(bytes : Bytes) : String
      Base64.strict_encode(bytes).rstrip('=')
    end

    private def self.unb64(text : String) : Bytes
      Base64.decode(text + "=" * ((4 - text.size % 4) % 4))
    rescue Base64::Error
      raise Error.new("Invalid base64 in Argon2 hash")
    end

    # :nodoc: the memory-filling loop (RFC 9106 section 3.4, reference implementation).
    class Filler
      @block_r = Slice(UInt64).new(BLOCK_WORDS, 0_u64)
      @block_tmp = Slice(UInt64).new(BLOCK_WORDS, 0_u64)
      @zero = Slice(UInt64).new(BLOCK_WORDS, 0_u64)
      @input = Slice(UInt64).new(BLOCK_WORDS, 0_u64)
      @address = Slice(UInt64).new(BLOCK_WORDS, 0_u64)

      def initialize(@memory : Slice(UInt64), @lanes : Int32, @lane_length : Int32, @segment_length : Int32, @blocks : Int32, @params : Params)
      end

      def fill_segment(pass : Int32, lane : Int32, slice : Int32) : Nil
        independent = @params.type.i? || (@params.type.id? && pass == 0 && slice < SYNC_POINTS // 2)
        if independent
          @input.fill(0_u64)
          @input[0] = pass.to_u64
          @input[1] = lane.to_u64
          @input[2] = slice.to_u64
          @input[3] = @blocks.to_u64
          @input[4] = @params.iterations.to_u64
          @input[5] = @params.type.value.to_u64
        end
        start = 0
        if pass == 0 && slice == 0
          start = 2
          next_addresses if independent
        end
        current = lane * @lane_length + slice * @segment_length + start
        previous = current % @lane_length == 0 ? current + @lane_length - 1 : current - 1
        (start...@segment_length).each do |index|
          previous = current - 1 if current % @lane_length == 1
          random = if independent
                     next_addresses if index % BLOCK_WORDS == 0
                     @address[index % BLOCK_WORDS]
                   else
                     @memory[previous * BLOCK_WORDS]
                   end
          ref_lane = pass == 0 && slice == 0 ? lane : ((random >> 32) % @lanes).to_i
          ref_index = reference_index(pass, slice, index, (random & 0xFFFFFFFF_u64), ref_lane == lane)
          fill_block(@memory + previous * BLOCK_WORDS, @memory + (@lane_length * ref_lane + ref_index) * BLOCK_WORDS,
            @memory + current * BLOCK_WORDS, pass != 0)
          current += 1
          previous += 1
        end
      end

      private def reference_index(pass : Int32, slice : Int32, index : Int32, random : UInt64, same_lane : Bool) : Int32
        area = if pass == 0
                 if slice == 0
                   index - 1
                 elsif same_lane
                   slice * @segment_length + index - 1
                 else
                   slice * @segment_length + (index == 0 ? -1 : 0)
                 end
               elsif same_lane
                 @lane_length - @segment_length + index - 1
               else
                 @lane_length - @segment_length + (index == 0 ? -1 : 0)
               end
        relative = (random &* random) >> 32
        relative = area.to_u64 - 1 - ((area.to_u64 &* relative) >> 32)
        start = pass != 0 && slice != SYNC_POINTS - 1 ? (slice + 1) * @segment_length : 0
        ((start.to_u64 + relative) % @lane_length).to_i
      end

      private def next_addresses : Nil
        @input[6] &+= 1
        fill_block(@zero, @input, @address, false)
        fill_block(@zero, @address, @address, false)
      end

      # next = G(prev, ref) (xor next on passes after the first).
      private def fill_block(prev : Slice(UInt64), ref : Slice(UInt64), target : Slice(UInt64), with_xor : Bool) : Nil
        r = @block_r.to_unsafe
        tmp = @block_tmp.to_unsafe
        BLOCK_WORDS.times do |i|
          value = ref[i] ^ prev[i]
          r[i] = value
          tmp[i] = with_xor ? value ^ target[i] : value
        end
        8.times do |i|
          base = 16 * i
          round(r, base, base + 1, base + 2, base + 3, base + 4, base + 5, base + 6, base + 7,
            base + 8, base + 9, base + 10, base + 11, base + 12, base + 13, base + 14, base + 15)
        end
        8.times do |i|
          base = 2 * i
          round(r, base, base + 1, base + 16, base + 17, base + 32, base + 33, base + 48, base + 49,
            base + 64, base + 65, base + 80, base + 81, base + 96, base + 97, base + 112, base + 113)
        end
        dest = target.to_unsafe
        BLOCK_WORDS.times { |i| dest[i] = tmp[i] ^ r[i] }
      end

      @[AlwaysInline]
      private def round(v : Pointer(UInt64), v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15) : Nil
        gb(v, v0, v4, v8, v12)
        gb(v, v1, v5, v9, v13)
        gb(v, v2, v6, v10, v14)
        gb(v, v3, v7, v11, v15)
        gb(v, v0, v5, v10, v15)
        gb(v, v1, v6, v11, v12)
        gb(v, v2, v7, v8, v13)
        gb(v, v3, v4, v9, v14)
      end

      @[AlwaysInline]
      private def gb(v : Pointer(UInt64), a, b, c, d) : Nil
        va, vb, vc, vd = v[a], v[b], v[c], v[d]
        va = va &+ vb &+ 2_u64 &* (va & 0xFFFFFFFF_u64) &* (vb & 0xFFFFFFFF_u64)
        vd = (vd ^ va).rotate_right(32)
        vc = vc &+ vd &+ 2_u64 &* (vc & 0xFFFFFFFF_u64) &* (vd & 0xFFFFFFFF_u64)
        vb = (vb ^ vc).rotate_right(24)
        va = va &+ vb &+ 2_u64 &* (va & 0xFFFFFFFF_u64) &* (vb & 0xFFFFFFFF_u64)
        vd = (vd ^ va).rotate_right(16)
        vc = vc &+ vd &+ 2_u64 &* (vc & 0xFFFFFFFF_u64) &* (vd & 0xFFFFFFFF_u64)
        vb = (vb ^ vc).rotate_right(63)
        v[a], v[b], v[c], v[d] = va, vb, vc, vd
      end
    end
  end
end
