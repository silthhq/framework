class Fiber
  # :nodoc:
  property silth_profile : Silth::Profiler::Profile?
  # :nodoc: the profile of a live action that raised, for the error message.
  property silth_failed_live_profile : Silth::Profiler::Profile?
end

module Silth
  # Development profiler: a toolbar on every HTML page plus a dashboard at
  # `/_silth/profiler` with a timeline of each request, its queries, logs,
  # translations, events, cache, mails, jobs, outgoing HTTP calls and
  # exceptions, and the app's routes, scheduled tasks and workflows.
  #
  # ```yaml
  # # config/profiler.yml
  # enabled: true            # default: development only
  # toolbar: true
  # keep: 200                # profiles kept in memory
  # slow_query_ms: 100
  # query_sources: true      # the line of app code behind each query (N+1 hunting)
  # ```
  module Profiler
    # Rows kept in a profile's timeline (queries, views, logs…).
    MAX_SPANS = 1000

    # A line of application code: where a query came from.
    record Source, file : String, line : Int32, method : String = "" do
      include JSON::Serializable

      def to_s(io : IO) : Nil
        io << file << ':' << line
      end
    end

    record QueryEntry, sql : String, args : Array(String), ms : Float64, connection : String, rows : Int32, start_ms : Float64 = 0.0,
      source : Source? = nil do
      include JSON::Serializable
    end

    # The same statement run several times from the same line of code: the
    # signature of an N+1 (a query inside a loop).
    record Repeat, sql : String, source : Source?, count : Int32, ms : Float64
    record LogEntry, level : String, source : String, message : String, at : Time, offset_ms : Float64 = 0.0 do
      include JSON::Serializable
    end
    record Entry, kind : String, label : String, detail : String, at : Time, ms : Float64? = nil, offset_ms : Float64? = nil do
      include JSON::Serializable
    end
    record ExceptionEntry, name : String, message : String, backtrace : Array(String), offset_ms : Float64 do
      include JSON::Serializable
    end

    # How a translation key was resolved during a request.
    class TranslationEntry
      include JSON::Serializable

      getter key : String
      getter locale : String
      getter status : String
      property count = 1

      def initialize(@key, @locale, @status)
      end

      def missing? : Bool
        @status == "missing"
      end
    end

    # One row of the request timeline. `start_ms` is relative to the start of
    # the request; `duration_ms` is nil while the span is still open (or for
    # instant events such as a log line).
    class Span
      include JSON::Serializable

      getter kind : String
      getter label : String
      getter detail : String
      getter start_ms : Float64
      property duration_ms : Float64?
      property level : String?
      property instant : Bool
      property source : Source?

      def initialize(@kind, @label, @detail, @start_ms, @duration_ms = nil, @level = nil, @instant = false, @source = nil)
      end

      def end_ms : Float64
        @start_ms + (@duration_ms || 0.0)
      end
    end

    # Translations keyed by {locale, key}, stored as a list in JSON.
    module TranslationsConverter
      def self.to_json(value : Hash({String, String}, TranslationEntry), json : JSON::Builder) : Nil
        json.array { value.each_value(&.to_json(json)) }
      end

      def self.from_json(pull : JSON::PullParser) : Hash({String, String}, TranslationEntry)
        Array(TranslationEntry).new(pull).to_h { |t| { {t.locale, t.key}, t } }
      end
    end

    class Profile
      include JSON::Serializable

      getter token : String = Crypto.hex_token(6)
      getter started_at : Time = Time.utc
      # The request's start on the monotonic clock (not kept when the profile is saved).
      @[JSON::Field(ignore: true)]
      getter clock : Time::Instant = Time.instant
      property method = ""
      property path = ""
      property url = ""
      property status = 0
      property route = "-"
      property handler = "-"
      property duration_ms = 0.0
      property memory_kb = 0_i64
      property user : String? = nil
      property ip = ""
      property locale = ""
      getter queries = [] of QueryEntry
      getter logs = [] of LogEntry
      getter entries = [] of Entry
      getter exceptions = [] of ExceptionEntry
      getter spans = [] of Span
      @[JSON::Field(converter: Silth::Profiler::TranslationsConverter)]
      getter translations = {} of {String, String} => TranslationEntry
      property request_headers = {} of String => String
      property response_headers = {} of String => String
      property params = {} of String => String
      property session = {} of String => String
      # The route's performance budget in milliseconds (see `Budget`).
      property budget_ms : Float64? = nil

      def initialize(@clock : Time::Instant = Time.instant)
      end

      # Milliseconds since the request started.
      def elapsed_ms : Float64
        (Time.instant - @clock).total_milliseconds
      end

      # The total time: final once the response is sent, the time elapsed so far before that.
      def total_ms : Float64
        @duration_ms > 0 ? @duration_ms : elapsed_ms
      end

      # Records a span that ended now and lasted `duration`.
      def span(kind : String, label : String, detail : String = "", duration : Time::Span? = nil, level : String? = nil) : Span?
        return if @spans.size >= MAX_SPANS
        now = elapsed_ms
        ms = duration.try(&.total_milliseconds)
        span = Span.new(kind, label, detail, ms ? {now - ms, 0.0}.max : now, ms, level, instant: ms.nil?)
        @spans << span
        span
      end

      # Opens a span (closed by `close_span`), for a controller action for example.
      def open_span(kind : String, label : String) : Span
        span = Span.new(kind, label, "", elapsed_ms)
        @spans << span
        span
      end

      def close_span(kind : String, label : String) : Nil
        if span = @spans.reverse_each.find { |s| s.kind == kind && s.label == label && s.duration_ms.nil? && !s.instant }
          span.duration_ms = elapsed_ms - span.start_ms
        end
      end

      def translation(key : String, locale : String, status : String) : Nil
        if entry = @translations[{locale, key}]?
          entry.count += 1
        elsif @translations.size < 500
          @translations[{locale, key}] = TranslationEntry.new(key, locale, status)
        end
      end

      def query_ms : Float64
        @queries.sum(&.ms)
      end

      def count(kind : String) : Int32
        @entries.count { |e| e.kind == kind }
      end

      def duplicated_queries : Int32
        @queries.group_by(&.sql).count { |_, v| v.size > 1 }
      end

      # Statements run more than once from the same line, most repeated first.
      def repeated_queries : Array(Repeat)
        @queries.group_by { |q| {q.sql, q.source} }.compact_map do |(sql, source), list|
          Repeat.new(sql, source, list.size, list.sum(&.ms)) if list.size > 1
        end.sort_by { |r| {-r.count, -r.ms} }
      end

      def slow_queries(threshold_ms : Number) : Int32
        @queries.count { |q| q.ms > threshold_ms }
      end

      def missing_translations : Array(TranslationEntry)
        @translations.values.select(&.missing?)
      end

      def log_count(*levels : String) : Int32
        @logs.count { |l| l.level.in?(levels) }
      end

      # The controller action span, when the request reached a controller.
      def action_span : Span?
        @spans.find { |s| s.kind == "controller" }
      end

      # Time spent before the action started (middleware, session, CSRF, auth).
      def before_action_ms : Float64?
        action_span.try(&.start_ms)
      end

      def action_ms : Float64?
        action_span.try { |s| s.duration_ms || (total_ms - s.start_ms) }
      end

      # Template rendering time (layouts and partials included, components counted inside them).
      def view_ms : Float64
        @spans.select { |s| s.kind == "view" }.sum { |s| s.duration_ms || 0.0 }
      end

      def status_class : String
        @status >= 500 ? "err" : @status >= 400 ? "warn" : "ok"
      end

      def over_budget? : Bool
        !!@budget_ms.try { |budget| total_ms > budget }
      end
    end

    @@profiles = Deque(Profile).new
    @@background = Deque(Entry).new
    @@mutex = Mutex.new
    @@enabled : Bool? = nil

    def self.enabled? : Bool
      @@enabled = Silth.config.bool("profiler.enabled", Silth.development?) if @@enabled.nil?
      @@enabled.not_nil!
    end

    def self.enabled=(value : Bool) : Nil
      @@enabled = value
    end

    # Profiles, newest first.
    def self.profiles : Array(Profile)
      @@mutex.synchronize { @@profiles.to_a.reverse }
    end

    def self.find(token : String) : Profile?
      @@mutex.synchronize { @@profiles.find { |p| p.token == token } }
    end

    def self.background : Array(Entry)
      @@mutex.synchronize { @@background.to_a.reverse }
    end

    def self.store(profile : Profile) : Nil
      keep = Silth.config.int("profiler.keep", 200)
      @@mutex.synchronize do
        @@profiles << profile
        while @@profiles.size > keep
          @@profiles.shift
        end
      end
      if storage = @@storage
        begin
          storage.save(profile, keep)
        rescue ex
          @@storage = nil
          ::Log.for("silth.profiler").warn { "Profiles are no longer saved to #{storage.path}: #{ex.message}" }
        end
      end
    end

    @@storage : Storage? = nil

    # Where profiles are saved (`profiler.persist`), nil when they live in memory only.
    def self.storage : Storage?
      @@storage
    end

    # Saves profiles to the SQLite file at *path* from now on and loads the ones
    # it already holds (`profiler.persist: true` does it at boot).
    def self.persist(path : String = Silth.config.string("profiler.persist_path", "tmp/profiler.sqlite3")) : Nil
      @@storage.try &.close
      storage = Storage.new(path)
      @@storage = storage
      keep = Silth.config.int("profiler.keep", 200)
      loaded = storage.load(keep)
      @@mutex.synchronize do
        known = @@profiles.map(&.token).to_set
        loaded.reject { |p| known.includes?(p.token) }.reverse_each { |p| @@profiles.unshift(p) }
        while @@profiles.size > keep
          @@profiles.shift
        end
      end
    end

    # Back to memory only.
    def self.stop_persisting : Nil
      @@storage.try &.close
      @@storage = nil
    end

    def self.slow_query_ms : Int32
      Silth.config.int("profiler.slow_query_ms", 100)
    end

    @@query_sources : Bool? = nil

    def self.query_sources? : Bool
      @@query_sources = Silth.config.bool("profiler.query_sources", true) if @@query_sources.nil?
      @@query_sources.not_nil!
    end

    def self.query_sources=(value : Bool) : Nil
      @@query_sources = value
    end

    FRAME = /\A(?<file>\S+?\.e?cr):(?<line>\d+)(?::\d+)? in '(?<method>.*)'\z/

    # The first frame of *frames* (a backtrace, `caller` by default) that belongs
    # to the application: not the framework, a shard or Crystal's standard
    # library. Needs debug information (development builds have it).
    #
    # ```
    # Profiler.app_source(["lib/silth/src/silth/db.cr:250:13 in 'query'", "src/controllers/posts_controller.cr:12:5 in 'show'"])
    # # => Source(file: "src/controllers/posts_controller.cr", line: 12, method: "show")
    # ```
    def self.app_source(frames : Array(String) = caller) : Source?
      root = Dir.current + "/"
      frames.each do |frame|
        m = frame.match(FRAME) || next
        file = m["file"].lchop(root)
        next if file.starts_with?('/') || file.starts_with?("lib/") || file.starts_with?("src/silth/") || file == "src/silth.cr"
        return Source.new(file, m["line"].to_i, m["method"])
      end
      nil
    end

    private def self.record_background(entry : Entry) : Nil
      @@mutex.synchronize do
        @@background << entry
        while @@background.size > 500
          @@background.shift
        end
      end
    end

    def self.clear : Nil
      @@mutex.synchronize { @@profiles.clear; @@background.clear }
      @@storage.try &.clear
    end

    def self.boot : Nil
      return unless enabled?
      if Silth.config.bool("profiler.persist", false)
        begin
          persist
        rescue ex
          ::Log.for("silth.profiler").warn { "Cannot save profiles (#{ex.message}): keeping them in memory" }
        end
      end
      Instrument.subscribe { |event| record(event, Fiber.current.silth_profile) }
      Logging.on_entry do |log|
        next if log.source.starts_with?("silth.http")
        level = log.severity.label.downcase
        if p = Fiber.current.silth_profile
          offset = p.elapsed_ms
          p.logs << LogEntry.new(level, log.source, log.message, log.timestamp, offset)
          p.span("log", log.message, log.source, level: level)
        elsif log.severity >= ::Log::Severity::Warn
          record_background(Entry.new("log", "#{level} #{log.source}", log.message, log.timestamp))
        end
      end
      ErrorReporter.on_report do |ex, _ctx|
        if p = Fiber.current.silth_profile
          p.exceptions << ExceptionEntry.new(ex.class.name, ex.message || "", (ex.backtrace? || [] of String).first(25), p.elapsed_ms)
          p.span("exception", ex.class.name, ex.message || "", level: "error")
        else
          record_background(Entry.new("exception", ex.class.name, ex.message || "", Time.utc))
        end
      end
    end

    # Profiles one live component action (a WebSocket message or a POST to
    # `/_silth/live`) as a request of its own, method `LIVE`: the action's
    # response carries its token so the toolbar lists it as a sub-request.
    def self.profile_live(label : String, & : -> String) : String
      return yield unless enabled?
      profile = Profile.new
      profile.method = "LIVE"
      profile.path = Live::Endpoint::PATH
      profile.url = label
      profile.route = Live::Endpoint::PATH
      profile.handler = label
      profile.budget_ms = Budget.for("LIVE", Live::Endpoint::PATH, label)
      previous = Fiber.current.silth_profile
      Fiber.current.silth_profile = profile
      begin
        result = yield
        profile.status = 200
        result
      rescue ex
        profile.status = ex.is_a?(HTTPError) ? ex.status.code : 500
        profile.exceptions << ExceptionEntry.new(ex.class.name, ex.message || "", (ex.backtrace? || [] of String).first(25), profile.elapsed_ms)
        Fiber.current.silth_failed_live_profile = profile
        raise ex
      ensure
        profile.duration_ms = profile.elapsed_ms
        store(profile)
        Fiber.current.silth_profile = previous
      end
    end

    # Adds an instrumentation event to the current request's profile, or to
    # the background activity when it happened outside a request.
    def self.record(event : Instrument::Event, profile : Profile?) : Nil
      case event
      when Instrument::Query
        if p = profile
          ms = event.duration.total_milliseconds
          source = query_sources? ? app_source : nil
          p.queries << QueryEntry.new(event.sql, event.args, ms, event.connection, event.rows, {p.elapsed_ms - ms, 0.0}.max, source)
          p.span("db", event.sql, "#{event.rows} rows · #{event.connection}#{source ? " · #{source}" : ""}", event.duration).try &.source=(source)
        end
        return
      when Instrument::Action
        if p = profile
          label = "#{event.controller}##{event.action}"
          event.duration ? p.close_span("controller", label) : p.open_span("controller", label)
        end
        return
      when Instrument::Translation
        profile.try &.translation(event.key, event.locale, event.status)
        return
      when Instrument::Render
        if p = profile
          template = event.template.lchop("src/views/")
          p.span(template.starts_with?("component ") ? "component" : "view", template.lchop("component "), "", event.duration)
        end
        return
      end
      entry = case event
              when Instrument::Cache        then Entry.new("cache", "#{event.operation} #{event.key}", event.hit ? "hit" : "miss", event.at)
              when Instrument::Mail         then Entry.new("mail", event.subject, "to #{event.to} (#{event.mailer})", event.at)
              when Instrument::Job          then Entry.new("job", event.name, "#{event.status} on #{event.queue}", event.at, event.duration.try(&.total_milliseconds))
              when Instrument::AppEvent     then Entry.new("event", event.name, "#{event.listeners} listener(s)", event.at)
              when Instrument::HTTPCall     then Entry.new("http", "#{event.method} #{event.url}", event.status.to_s, event.at, event.duration.total_milliseconds)
              when Instrument::Notification then Entry.new("notification", event.name, event.channels, event.at)
              when Instrument::Custom       then Entry.new("custom", event.name, event.data.map { |k, v| "#{k}=#{v}" }.join(" "), event.at)
              end
      return unless entry
      if p = profile
        ms = entry.ms
        p.entries << entry.copy_with(offset_ms: p.elapsed_ms - (ms || 0.0))
        p.span(entry.kind, entry.label, entry.detail, ms.try(&.milliseconds))
      else
        record_background(entry)
      end
    end

    # Collects the profile and serves the dashboard.
    class Middleware < Silth::Middleware
      PREFIX = "/_silth/profiler"

      def call(ctx : Context, chain : Chain) : Nil
        if ctx.path.starts_with?(PREFIX)
          return Dashboard.serve(ctx)
        end
        if ctx.path.starts_with?("/_silth/") || ctx.path.starts_with?("/assets/")
          return chain.next(ctx)
        end
        profile = Profile.new(ctx.started_at)
        profile.method = ctx.method
        profile.path = ctx.path
        profile.url = ctx.request.resource
        profile.ip = ctx.remote_ip
        Fiber.current.silth_profile = profile
        before_heap = GC.stats.heap_size
        ctx.response.headers["X-Silth-Profile"] = profile.token
        if Silth.config.bool("profiler.toolbar", true)
          ctx.filter_body do |body, content_type|
            collect(ctx, profile, before_heap)
            if content_type.starts_with?("text/html") && (idx = body.rindex("</body>"))
              body.insert(idx, Toolbar.render(profile, ctx.csp_nonce))
            else
              body
            end
          end
        end
        begin
          chain.next(ctx)
        ensure
          collect(ctx, profile, before_heap)
          profile.duration_ms = ctx.duration_ms
          Profiler.store(profile)
          Fiber.current.silth_profile = nil
        end
      end

      private def collect(ctx : Context, profile : Profile, before_heap) : Nil
        profile.status = ctx.status
        profile.route = ctx.route.try(&.path) || "-"
        profile.handler = ctx.route.try(&.handler_name) || "-"
        profile.budget_ms = ctx.route.try { |r| Budget.for(r.method, r.path, r.handler_name) }
        profile.memory_kb = ((GC.stats.heap_size.to_i64 - before_heap.to_i64) // 1024)
        profile.user = ctx.auth_user.try { |u| "#{u.class.name}##{u.auth_id}" }
        profile.locale = ctx.locale
        profile.request_headers = ctx.request.headers.to_h.transform_values(&.join(", ")).reject { |k, _| k.downcase.in?("cookie", "authorization") }
        profile.response_headers = ctx.response.headers.to_h.transform_values(&.join(", ")).reject { |k, _| k.downcase == "set-cookie" }
        profile.params = ctx.params?.try(&.to_h.reject { |k, _| k.downcase.includes?("password") || k == "_csrf" }) || {} of String => String
        profile.session = ctx.session?.try(&.data.reject { |k, _| k.starts_with?("_csrf") }) || {} of String => String
      end
    end
  end
end

require "./profiler/editor"
require "./profiler/storage"
require "./profiler/budget"
require "./profiler/timeline"
require "./profiler/toolbar"
require "./profiler/mail_viewer"
require "./profiler/dashboard"
