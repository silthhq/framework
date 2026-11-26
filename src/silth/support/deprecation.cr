module Silth
  # Deprecation warnings, following the compatibility policy: a deprecated API
  # keeps working for one minor version (deprecated in 0.2, removed in 0.3) and
  # warns until then.
  #
  # Methods use Crystal's annotation, a warning at compile time:
  #
  # ```
  # @[Deprecated("Use `Silth.cache` instead. Removed in 0.3.")]
  # def self.store : CacheStore
  #   Silth.cache
  # end
  # ```
  #
  # Configuration keys and runtime behaviors use `Silth.deprecated`, which logs
  # once per process (and raises with `SILTH_DEPRECATIONS=raise`, handy in CI):
  #
  # ```
  # if value = Silth.config.int?("profiler.keep_profiles")
  #   Silth.deprecated("profiler.keep_profiles", instead: "profiler.keep", removed_in: "0.3")
  # end
  # ```
  module Deprecation
    Log = ::Log.for("silth.deprecation")

    class Error < Silth::Error; end

    @@seen = Set(String).new
    @@mutex = Mutex.new

    # Logs *what* is deprecated (once per process) and what to use instead.
    def self.warn(what : String, instead : String? = nil, removed_in : String? = nil) : Nil
      message = String.build do |io|
        io << what << " is deprecated"
        io << ", use " << instead << " instead" if instead
        io << " (removed in " << removed_in << ")" if removed_in
      end
      raise Error.new(message) if ENV["SILTH_DEPRECATIONS"]? == "raise"
      first = @@mutex.synchronize { @@seen.add?(message) }
      Log.warn { message } if first
    end

    # Messages logged so far, in order.
    def self.warnings : Array(String)
      @@mutex.synchronize { @@seen.to_a }
    end

    def self.reset : Nil
      @@mutex.synchronize { @@seen.clear }
    end
  end

  # Shortcut for `Deprecation.warn`.
  def self.deprecated(what : String, instead : String? = nil, removed_in : String? = nil) : Nil
    Deprecation.warn(what, instead, removed_in)
  end
end
