require "json"

module Silth
  # How `Time` values are written to JSON, everywhere: models, hashes,
  # `JSON::Serializable` structs. Always RFC 3339 in UTC (`Z`), with a fixed
  # number of fractional digits or just what the value needs:
  #
  # ```yaml
  # # config/app.yml
  # json_time_precision: 3      # 2026-11-27T10:00:00.000Z (default)
  # json_time_precision: auto   # 2026-11-27T10:00:00Z, 2026-11-27T10:00:00.250Z, …123456Z
  # json_time_precision: 0      # 2026-11-27T10:00:00Z (truncated)
  # ```
  #
  # `auto` writes no fraction for a whole second, else 3, 6 or 9 digits (as
  # Rust's chrono does), so microseconds read from PostgreSQL are not lost.
  module JSONTime
    @@digits : Int32? = 3

    # Fractional digits, or nil for `auto`.
    def self.digits : Int32?
      @@digits
    end

    def self.digits=(value : Int32?) : Nil
      raise ArgumentError.new("json_time_precision must be auto, 0, 3, 6 or 9") if value && !value.in?(0, 3, 6, 9)
      @@digits = value
    end

    # Applies `app.json_time_precision` (`auto`, `0`, `3`, `6` or `9`).
    def self.configure(setting : String) : Nil
      self.digits = setting.strip.downcase == "auto" ? nil : setting.to_i
    end

    def self.format(time : Time, io : IO) : Nil
      JSONWriter.time(io, time, @@digits)
    end

    def self.format(time : Time) : String
      String.build { |io| format(time, io) }
    end
  end
end

struct Time
  # RFC 3339 in UTC, with the precision set by `Silth::JSONTime`.
  def to_json(json : JSON::Builder) : Nil
    json.__silth_raw { |io| Silth::JSONWriter.value(io, self) }
  end
end
