require "digest/sha512"

module Silth::DB::MySQL
  # Ed25519 signatures (RFC 8032) for MariaDB's `client_ed25519` and `parsec`
  # authentication plugins.
  #
  # `client_ed25519` derives the signing key from SHA-512 of the password itself,
  # whatever its length, where standard Ed25519 hashes a 32-byte seed: OpenSSL's
  # EVP API only takes the seed, so the curve arithmetic lives here. With a 32-byte
  # secret, `sign` is standard Ed25519 (what `parsec` uses, with a PBKDF2 key).
  #
  # ```
  # MySQL::Ed25519.sign(nonce, "secret".to_slice) # => 64 bytes: R || S
  # ```
  #
  # Field elements use five 51-bit limbs and 128-bit products; scalar
  # multiplication and the reductions modulo L run without branches on secret
  # data.
  module Ed25519
    extend self

    # An element of GF(2^255 - 19): five unsigned 51-bit limbs (lowest first).
    struct Fe
      MASK = (1_u64 << 51) - 1
      # 4p, added before a subtraction to stay positive.
      FOUR_P = StaticArray[(MASK - 18) * 4, MASK * 4, MASK * 4, MASK * 4, MASK * 4]

      getter limbs : StaticArray(UInt64, 5)

      def initialize(@limbs : StaticArray(UInt64, 5))
      end

      def self.from_int(value : UInt64) : Fe
        new(StaticArray[value, 0_u64, 0_u64, 0_u64, 0_u64])
      end

      def self.zero : Fe
        from_int(0)
      end

      def self.one : Fe
        from_int(1)
      end

      # Reads 32 little-endian bytes, ignoring the top bit.
      def self.from_bytes(bytes : Bytes) : Fe
        limbs = StaticArray(UInt64, 5).new(0_u64)
        acc = 0_u128
        bits = 0
        index = 0
        bytes[0, 32].each do |byte|
          acc |= byte.to_u128 << bits
          bits += 8
          if bits >= 51 && index < 5
            limbs[index] = (acc & MASK).to_u64
            acc >>= 51
            bits -= 51
            index += 1
          end
        end
        limbs[4] = (acc & MASK).to_u64 if index == 4
        new(limbs)
      end

      def +(other : Fe) : Fe
        Fe.new(StaticArray(UInt64, 5).new { |i| @limbs[i] + other.limbs[i] }).carry
      end

      def -(other : Fe) : Fe
        Fe.new(StaticArray(UInt64, 5).new { |i| @limbs[i] + FOUR_P[i] - other.limbs[i] }).carry
      end

      def - : Fe
        Fe.zero - self
      end

      def *(other : Fe) : Fe
        a = @limbs
        b = other.limbs
        a0, a1, a2, a3, a4 = a[0].to_u128, a[1].to_u128, a[2].to_u128, a[3].to_u128, a[4].to_u128
        b0, b1, b2, b3, b4 = b[0].to_u128, b[1].to_u128, b[2].to_u128, b[3].to_u128, b[4].to_u128
        b1_19, b2_19, b3_19, b4_19 = b1 * 19, b2 * 19, b3 * 19, b4 * 19
        r0 = a0 * b0 + a1 * b4_19 + a2 * b3_19 + a3 * b2_19 + a4 * b1_19
        r1 = a0 * b1 + a1 * b0 + a2 * b4_19 + a3 * b3_19 + a4 * b2_19
        r2 = a0 * b2 + a1 * b1 + a2 * b0 + a3 * b4_19 + a4 * b3_19
        r3 = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0 + a4 * b4_19
        r4 = a0 * b4 + a1 * b3 + a2 * b2 + a3 * b1 + a4 * b0
        r1 += r0 >> 51
        r2 += r1 >> 51
        r3 += r2 >> 51
        r4 += r3 >> 51
        c = r4 >> 51
        l0 = (r0 & MASK) + c * 19
        Fe.new(StaticArray[(l0 & MASK).to_u64, ((r1 & MASK) + (l0 >> 51)).to_u64, (r2 & MASK).to_u64, (r3 & MASK).to_u64, (r4 & MASK).to_u64])
      end

      def square : Fe
        self * self
      end

      # Limbs back under 2^51 (the top carry wraps around times 19).
      protected def carry : Fe
        l = @limbs
        4.times do |i|
          l[i + 1] += l[i] >> 51
          l[i] &= MASK
        end
        l[0] += (l[4] >> 51) * 19
        l[4] &= MASK
        l[1] += l[0] >> 51
        l[0] &= MASK
        Fe.new(l)
      end

      # `self ** exponent`, the exponent as 32 little-endian bytes (public values only).
      def pow(exponent : Bytes) : Fe
        result = Fe.one
        255.downto(0) do |i|
          result = result.square
          result *= self if (exponent[i >> 3] >> (i & 7)) & 1 == 1
        end
        result
      end

      def invert : Fe
        pow(Ed25519::P_MINUS_2)
      end

      # Canonical 32-byte little-endian encoding (fully reduced modulo p).
      def to_bytes : Bytes
        l = carry.carry.limbs
        q = (l[0] + 19) >> 51
        q = (l[1] + q) >> 51
        q = (l[2] + q) >> 51
        q = (l[3] + q) >> 51
        q = (l[4] + q) >> 51 # 1 when the value is >= p
        l[0] += 19 * q
        4.times do |i|
          l[i + 1] += l[i] >> 51
          l[i] &= MASK
        end
        l[4] &= MASK
        out = Bytes.new(32)
        acc = 0_u128
        bits = 0
        index = 0
        l.each do |limb|
          acc |= limb.to_u128 << bits
          bits += 51
          while bits >= 8
            out[index] = (acc & 0xff).to_u8
            acc >>= 8
            bits -= 8
            index += 1
          end
        end
        out[31] = (acc & 0xff).to_u8 if index == 31
        out
      end

      def ==(other : Fe) : Bool
        to_bytes == other.to_bytes
      end

      def odd? : Bool
        to_bytes[0] & 1 == 1
      end

      # Constant time: *other* when *flag* is 1, self when it is 0.
      def select(other : Fe, flag : UInt64) : Fe
        mask = 0_u64 &- flag
        Fe.new(StaticArray(UInt64, 5).new { |i| (@limbs[i] & ~mask) | (other.limbs[i] & mask) })
      end
    end

    # A point of edwards25519 in extended coordinates (X:Y:Z:T), x = X/Z, y = Y/Z, xy = T/Z.
    record Point, x : Fe, y : Fe, z : Fe, t : Fe do
      def self.identity : Point
        new(Fe.zero, Fe.one, Fe.one, Fe.zero)
      end

      # Complete addition for a = -1 (add-2008-hwcd-3): also doubles.
      def +(other : Point) : Point
        a = (y - x) * (other.y - other.x)
        b = (y + x) * (other.y + other.x)
        c = t * Ed25519.d2 * other.t
        zz = z * other.z
        d = zz + zz
        e = b - a
        f = d - c
        g = d + c
        h = b + a
        Point.new(e * f, g * h, f * g, e * h)
      end

      def select(other : Point, flag : UInt64) : Point
        Point.new(x.select(other.x, flag), y.select(other.y, flag), z.select(other.z, flag), t.select(other.t, flag))
      end

      # 32 bytes: y, with the parity of x in the top bit.
      def encode : Bytes
        zi = z.invert
        bytes = (y * zi).to_bytes
        bytes[31] |= (x * zi).odd? ? 0x80_u8 : 0_u8
        bytes
      end
    end

    # Exponents (little-endian) used by inversion and square roots.
    P_MINUS_2       = exponent(0xeb, 0x7f) # p - 2
    P_MINUS_5_DIV_8 = exponent(0xfd, 0x0f) # (p - 5) / 8
    P_MINUS_1_DIV_4 = exponent(0xfb, 0x1f) # (p - 1) / 4

    # The group order L = 2^252 + 27742317777372353535851937790883648493, little-endian.
    L = Bytes[0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10]

    # Encoding of the base point (y = 4/5, x even).
    BASE_ENCODED = Bytes.new(32) { |i| i == 0 ? 0x58_u8 : 0x66_u8 }

    # :nodoc:
    def self.exponent(low : Int32, high : Int32) : Bytes
      bytes = Bytes.new(32, 0xff_u8)
      bytes[0] = low.to_u8
      bytes[31] = high.to_u8
      bytes
    end

    @@d : Fe?
    @@d2 : Fe?
    @@sqrt_m1 : Fe?
    @@base : Point?

    # d = -121665 / 121666
    def d : Fe
      @@d ||= -Fe.from_int(121665) * Fe.from_int(121666).invert
    end

    def d2 : Fe
      @@d2 ||= d + d
    end

    def sqrt_m1 : Fe
      @@sqrt_m1 ||= Fe.from_int(2).pow(P_MINUS_1_DIV_4)
    end

    def base : Point
      @@base ||= decode(BASE_ENCODED) || raise "invalid Ed25519 base point"
    end

    # The point a 32-byte encoding names, nil when it is not on the curve.
    def decode(bytes : Bytes) : Point?
      y = Fe.from_bytes(bytes)
      y2 = y.square
      u = y2 - Fe.one
      v = d * y2 + Fe.one
      v3 = v.square * v
      x = u * v3 * (u * v3.square * v).pow(P_MINUS_5_DIV_8)
      vx2 = v * x.square
      if vx2 == u
      elsif vx2 == -u
        x *= sqrt_m1
      else
        return nil
      end
      x = -x if x.odd? != (bytes[31] >> 7 == 1)
      Point.new(x, y, Fe.one, x * y)
    end

    # scalar · B, with a double-and-add that always adds and selects in constant time.
    def scalar_mult_base(scalar : Bytes) : Point
      q = Point.identity
      b = base
      255.downto(0) do |i|
        q += q
        q = q.select(q + b, ((scalar[i >> 3] >> (i & 7)) & 1).to_u64)
      end
      q
    end

    # The public key of *secret* (32 bytes).
    def public_key(secret : Bytes) : Bytes
      scalar_mult_base(clamped(sha512(secret))).encode
    end

    # Signs *message* with the key derived from *secret*: 64 bytes, R || S.
    def sign(message : Bytes, secret : Bytes) : Bytes
      az = sha512(secret)
      a = clamped(az)
      public = scalar_mult_base(a).encode
      r = reduce(sha512(az[32, 32], message))
      big_r = scalar_mult_base(r).encode
      h = reduce(sha512(big_r, public, message))
      signature = Bytes.new(64)
      big_r.copy_to(signature)
      mul_add(h, a, r).copy_to(signature + 32)
      signature
    end

    private def clamped(az : Bytes) : Bytes
      a = az[0, 32].dup
      a[0] &= 248_u8
      a[31] &= 63_u8
      a[31] |= 64_u8
      a
    end

    private def sha512(*parts : Bytes) : Bytes
      digest = Digest::SHA512.new
      parts.each { |part| digest.update(part) }
      digest.final
    end

    # A little-endian number (up to 68 bytes) modulo L, bit by bit: shift in the
    # next bit, then subtract L when the remainder reaches it (selected by mask).
    def reduce(bytes : Bytes) : Bytes
      l = limbs32(L, 9)
      r = StaticArray(UInt32, 9).new(0_u32)
      (bytes.size * 8 - 1).downto(0) do |i|
        carry = ((bytes[i >> 3] >> (i & 7)) & 1).to_u64
        9.times do |j|
          v = (r[j].to_u64 << 1) | carry
          r[j] = v.to_u32!
          carry = v >> 32
        end
        diff = StaticArray(UInt32, 9).new(0_u32)
        borrow = 0_u64
        9.times do |j|
          v = r[j].to_u64 &- l[j].to_u64 &- borrow
          diff[j] = v.to_u32!
          borrow = (v >> 63) & 1
        end
        keep = 0_u32 &- borrow.to_u32 # all ones when r < L
        9.times { |j| r[j] = (r[j] & keep) | (diff[j] & ~keep) }
      end
      out = Bytes.new(32)
      8.times { |j| 4.times { |k| out[j * 4 + k] = (r[j] >> (8 * k)).to_u8! } }
      out
    end

    # (a · b + c) mod L for 32-byte little-endian scalars.
    def mul_add(a : Bytes, b : Bytes, c : Bytes) : Bytes
      x = limbs32(a, 8)
      y = limbs32(b, 8)
      product = StaticArray(UInt32, 17).new(0_u32)
      8.times do |i|
        carry = 0_u64
        8.times do |j|
          t = product[i + j].to_u64 + x[i].to_u64 * y[j].to_u64 + carry
          product[i + j] = t.to_u32!
          carry = t >> 32
        end
        product[i + 8] = carry.to_u32!
      end
      addend = limbs32(c, 8)
      carry = 0_u64
      17.times do |i|
        t = product[i].to_u64 + (i < 8 ? addend[i].to_u64 : 0_u64) + carry
        product[i] = t.to_u32!
        carry = t >> 32
      end
      bytes = Bytes.new(68)
      17.times { |j| 4.times { |k| bytes[j * 4 + k] = (product[j] >> (8 * k)).to_u8! } }
      reduce(bytes)
    end

    private def limbs32(bytes : Bytes, count : Int32) : Array(UInt32)
      Array(UInt32).new(count) do |j|
        v = 0_u32
        4.times { |k| v |= (bytes[j * 4 + k]? || 0_u8).to_u32 << (8 * k) }
        v
      end
    end
  end
end
