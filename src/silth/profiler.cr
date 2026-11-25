class Fiber
  # :nodoc:
  property silth_profile : Silth::Profiler::Profile?
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
  # ```
  module Profiler
    # Rows kept in a profile's timeline (queries, views, logs…).
    MAX_SPANS = 1000

    record QueryEntry, sql : String, args : Array(String), ms : Float64, connection : String, rows : Int32, start_ms : Float64 = 0.0
    record LogEntry, level : String, source : String, message : String, at : Time, offset_ms : Float64 = 0.0
    record Entry, kind : String, label : String, detail : String, at : Time, ms : Float64? = nil, offset_ms : Float64? = nil
    record ExceptionEntry, name : String, message : String, backtrace : Array(String), offset_ms : Float64

    # How a translation key was resolved during a request.
    class TranslationEntry
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
      getter kind : String
      getter label : String
      getter detail : String
      getter start_ms : Float64
      property duration_ms : Float64?
      property level : String?
      property instant : Bool

      def initialize(@kind, @label, @detail, @start_ms, @duration_ms = nil, @level = nil, @instant = false)
      end

      def end_ms : Float64
        @start_ms + (@duration_ms || 0.0)
      end
    end

    class Profile
      getter token : String = Crypto.hex_token(6)
      getter started_at : Time = Time.utc
      getter clock : Time::Instant
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
      getter translations = {} of {String, String} => TranslationEntry
      property request_headers = {} of String => String
      property response_headers = {} of String => String
      property params = {} of String => String
      property session = {} of String => String

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
    end

    def self.slow_query_ms : Int32
      Silth.config.int("profiler.slow_query_ms", 100)
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
    end

    def self.boot : Nil
      return unless enabled?
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

    # Adds an instrumentation event to the current request's profile, or to
    # the background activity when it happened outside a request.
    def self.record(event : Instrument::Event, profile : Profile?) : Nil
      case event
      when Instrument::Query
        if p = profile
          ms = event.duration.total_milliseconds
          p.queries << QueryEntry.new(event.sql, event.args, ms, event.connection, event.rows, {p.elapsed_ms - ms, 0.0}.max)
          p.span("db", event.sql, "#{event.rows} rows · #{event.connection}", event.duration)
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

require "./profiler/timeline"
require "./profiler/toolbar"
require "./profiler/mail_viewer"
require "./profiler/dashboard"
