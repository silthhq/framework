require "log"
require "colorize"
require "json"

module Silth
  # Structured logging on top of Crystal's `Log`.
  #
  # ```yaml
  # # config/logging.yml
  # level: info          # trace, debug, info, notice, warn, error, fatal
  # format: pretty       # pretty | json
  # file: log/app.log    # optional extra file output
  # when@production:
  #   format: json
  # ```
  module Logging
    LEVEL_COLORS = {
      ::Log::Severity::Trace  => :dark_gray,
      ::Log::Severity::Debug  => :dark_gray,
      ::Log::Severity::Info   => :cyan,
      ::Log::Severity::Notice => :light_cyan,
      ::Log::Severity::Warn   => :yellow,
      ::Log::Severity::Error  => :red,
      ::Log::Severity::Fatal  => :light_red,
    }

    # Human friendly, colored output for development.
    struct PrettyFormatter
      include ::Log::Formatter

      def initialize(@colors : Bool = true)
      end

      def format(entry : ::Log::Entry, io : IO) : Nil
        time = entry.timestamp.to_local.to_s("%H:%M:%S.%L")
        level = entry.severity.label.ljust(6)
        color = LEVEL_COLORS[entry.severity]? || :default
        if @colors
          io << time.colorize(:dark_gray) << " " << level.colorize(color).bold
          io << " " << entry.source.colorize(:magenta) unless entry.source.empty?
          io << " " << entry.message
        else
          io << time << " " << level
          io << " " << entry.source unless entry.source.empty?
          io << " " << entry.message
        end
        write_metadata(io, entry.context)
        write_metadata(io, entry.data)
        if ex = entry.exception
          io << "\n" << (@colors ? ex.inspect_with_backtrace.colorize(:red) : ex.inspect_with_backtrace)
        end
      end

      private def write_metadata(io, metadata : ::Log::Metadata)
        return if metadata.empty?
        metadata.each do |key, value|
          io << " " << (@colors ? key.to_s.colorize(:dark_gray) : key.to_s) << "=" << value.to_s
        end
      end
    end

    # One JSON object per line, ready for log shippers. Includes trace ids when present.
    struct JSONFormatter
      include ::Log::Formatter

      def initialize
      end

      def format(entry : ::Log::Entry, io : IO) : Nil
        JSON.build(io) do |json|
          json.object do
            json.field "ts", entry.timestamp.to_rfc3339(fraction_digits: 6)
            json.field "level", entry.severity.label.downcase
            json.field "source", entry.source unless entry.source.empty?
            json.field "msg", entry.message
            entry.context.each { |k, v| json.field k.to_s, v.to_s }
            entry.data.each { |k, v| json.field k.to_s, v.to_s }
            if ex = entry.exception
              json.field "exception", ex.class.name
              json.field "error", ex.message
              json.field "backtrace", (ex.backtrace? || [] of String).first(20)
            end
          end
        end
      end
    end

    # In-memory backend used by tests and the profiler.
    class MemoryBackend < ::Log::Backend
      getter entries = [] of ::Log::Entry
      @mutex = Mutex.new

      def initialize
        super(:direct)
      end

      def write(entry : ::Log::Entry) : Nil
        @mutex.synchronize { @entries << entry }
      end

      def clear
        @mutex.synchronize { @entries.clear }
      end

      def messages : Array(String)
        @mutex.synchronize { @entries.map(&.message) }
      end
    end

    # Backend forwarding entries to registered listeners (profiler, telemetry…).
    class HookBackend < ::Log::Backend
      def initialize
        super(:direct)
      end

      def write(entry : ::Log::Entry) : Nil
        Logging.hooks.each &.call(entry)
      end
    end

    class_getter hooks = [] of ::Log::Entry -> Nil

    def self.on_entry(&block : ::Log::Entry -> Nil) : Nil
      @@hooks << block
    end

    def self.setup(config : Config, env : String) : Nil
      level = ::Log::Severity.parse?(config.string("logging.level", env == "production" ? "info" : "debug")) || ::Log::Severity::Info
      format = config.string("logging.format", env == "production" ? "json" : "pretty")
      formatter = format == "json" ? JSONFormatter.new.as(::Log::Formatter) : PrettyFormatter.new(STDOUT.tty?).as(::Log::Formatter)

      broadcast = ::Log::BroadcastBackend.new
      if env == "test"
        broadcast.append(::Log::IOBackend.new(File.open(File::NULL, "w"), formatter: formatter), level)
      else
        broadcast.append(::Log::IOBackend.new(STDOUT, formatter: formatter, dispatcher: :sync), level)
      end
      if path = config.string?("logging.file")
        Dir.mkdir_p(File.dirname(path))
        file = File.new(path, "a")
        broadcast.append(::Log::IOBackend.new(file, formatter: JSONFormatter.new, dispatcher: :sync), level)
      end
      if config.keys("logging").includes?("postgres")
        pg_level = ::Log::Severity.parse?(config.string("logging.postgres.level", "info")) || ::Log::Severity::Info
        retention = config.int("logging.postgres.retention_days", 14).days
        broadcast.append(PostgresBackend.new(config.string?("logging.postgres.connection"), retention), pg_level)
      end
      broadcast.append(HookBackend.new, ::Log::Severity::Trace)
      ::Log.setup do |c|
        c.bind "*", ::Log::Severity::Trace, broadcast
      end
    end
  end
end
