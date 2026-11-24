require "http/client"

class Fiber
  # :nodoc:
  property silth_span : Silth::Telemetry::Span?
end

module Silth
  # OpenTelemetry tracing and metrics exported with OTLP/HTTP (JSON encoding).
  #
  # Enable with `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318` or `config/telemetry.yml`:
  #
  # ```yaml
  # enabled: true
  # service_name: my-app
  # endpoint: http://localhost:4318
  # sample_rate: 1.0
  # ```
  #
  # ```
  # Silth::Telemetry.trace("checkout.charge", attributes: {"order.id" => order.id.to_s}) do |span|
  #   span.add_event("payment.authorized")
  # end
  # Silth::Telemetry.counter("orders.created").add(1)
  # ```
  module Telemetry
    Log = ::Log.for("silth.telemetry")

    enum Kind
      Internal = 1
      Server   = 2
      Client   = 3
      Producer = 4
      Consumer = 5
    end

    alias AttrValue = String | Int64 | Float64 | Bool

    class Span
      getter trace_id : String
      getter span_id : String
      getter parent_id : String?
      property name : String
      getter kind : Kind
      getter start_time : Time
      getter end_time : Time?
      getter attributes = {} of String => AttrValue
      getter events = [] of {String, Time, Hash(String, AttrValue)}
      property status_code = 0
      property status_message : String? = nil
      getter? sampled : Bool

      def initialize(@name, @kind, @trace_id, @parent_id, @sampled, @start_time = Time.utc)
        @span_id = Random::Secure.hex(8)
      end

      def set(key : String, value) : self
        @attributes[key] = case value
                           when String, Int64, Float64, Bool then value
                           when Int                          then value.to_i64
                           when Float                        then value.to_f64
                           else                                   value.to_s
                           end
        self
      end

      def add_event(name : String, attributes = {} of String => AttrValue) : Nil
        @events << {name, Time.utc, attributes}
      end

      def record_exception(ex : Exception) : Nil
        add_event("exception", {"exception.type" => ex.class.name.as(AttrValue), "exception.message" => (ex.message || "").as(AttrValue),
                                "exception.stacktrace" => (ex.backtrace? || [] of String).first(30).join('\n').as(AttrValue)})
        @status_code = 2
        @status_message = ex.message
      end

      def finish(at : Time = Time.utc) : Nil
        return if @end_time
        @end_time = at
        Telemetry.exporter.try &.enqueue(self) if @sampled
      end

      def traceparent : String
        "00-#{@trace_id}-#{@span_id}-#{@sampled ? "01" : "00"}"
      end

      def duration : Time::Span
        (@end_time || Time.utc) - @start_time
      end
    end

    # Batches spans and metrics, posting them to the collector in the background.
    class Exporter
      @spans = [] of Span
      @mutex = Mutex.new

      def initialize(@endpoint : String, @service : String, @headers : Hash(String, String) = {} of String => String, @interval : Time::Span = 5.seconds)
        spawn(name: "otel-exporter") do
          loop do
            sleep @interval
            flush rescue nil
          end
        end
      end

      def enqueue(span : Span) : Nil
        @mutex.synchronize { @spans << span }
        flush if @spans.size >= 512
      end

      def flush : Nil
        batch = @mutex.synchronize { @spans.dup.tap { @spans.clear } }
        post("/v1/traces", traces_json(batch)) unless batch.empty?
        metrics = Telemetry.metrics_json(resource)
        post("/v1/metrics", metrics) if metrics
      end

      private def post(path : String, body : String) : Nil
        uri = URI.parse(@endpoint.rstrip('/') + path)
        headers = HTTP::Headers{"Content-Type" => "application/json"}
        @headers.each { |k, v| headers[k] = v }
        response = HTTP::Client.post(uri, headers: headers, body: body)
        Log.warn { "OTLP export to #{path} failed: #{response.status_code}" } unless response.success?
      rescue ex
        Log.debug { "OTLP export failed: #{ex.message}" }
      end

      def resource : String
        {attributes: Telemetry.attributes_json({"service.name" => @service.as(AttrValue), "service.version" => Silth.config.string("app.version", "0.0.0").as(AttrValue),
                                                "deployment.environment.name" => Silth.env.as(AttrValue), "telemetry.sdk.name" => "silth".as(AttrValue),
                                                "telemetry.sdk.language" => "crystal".as(AttrValue), "telemetry.sdk.version" => Silth::VERSION.as(AttrValue)})}.to_json
      end

      private def traces_json(spans : Array(Span)) : String
        JSON.build do |j|
          j.object do
            j.field "resourceSpans" do
              j.array do
                j.object do
                  j.field("resource") { j.raw(resource) }
                  j.field "scopeSpans" do
                    j.array do
                      j.object do
                        j.field("scope") { j.object { j.field "name", "silth"; j.field "version", Silth::VERSION } }
                        j.field "spans" do
                          j.array do
                            spans.each do |s|
                              j.object do
                                j.field "traceId", s.trace_id
                                j.field "spanId", s.span_id
                                j.field "parentSpanId", s.parent_id if s.parent_id
                                j.field "name", s.name
                                j.field "kind", s.kind.value
                                j.field "startTimeUnixNano", Telemetry.nanos(s.start_time)
                                j.field "endTimeUnixNano", Telemetry.nanos(s.end_time || Time.utc)
                                j.field("attributes") { j.raw(Telemetry.attributes_json(s.attributes)) }
                                j.field "events" do
                                  j.array do
                                    s.events.each do |(name, at, attrs)|
                                      j.object do
                                        j.field "name", name
                                        j.field "timeUnixNano", Telemetry.nanos(at)
                                        j.field("attributes") { j.raw(Telemetry.attributes_json(attrs)) }
                                      end
                                    end
                                  end
                                end
                                j.field("status") { j.object { j.field "code", s.status_code; j.field "message", s.status_message if s.status_message } }
                              end
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    # --- metrics -------------------------------------------------------------

    class Counter
      getter name : String
      getter unit : String
      getter values = Hash(String, Float64).new(0.0)
      @mutex = Mutex.new

      def initialize(@name, @unit = "1")
      end

      def add(value : Number = 1, attributes : Hash(String, String) = {} of String => String) : Nil
        key = attributes.to_json
        @mutex.synchronize { @values[key] += value.to_f64 }
      end
    end

    class Histogram
      BOUNDS = [0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0]
      getter name : String
      getter unit : String
      getter series = {} of String => {Array(Int64), Int64, Float64}
      @mutex = Mutex.new

      def initialize(@name, @unit = "s")
      end

      def record(value : Float64, attributes : Hash(String, String) = {} of String => String) : Nil
        key = attributes.to_json
        @mutex.synchronize do
          buckets, count, sum = @series[key]? || {Array(Int64).new(BOUNDS.size + 1, 0_i64), 0_i64, 0.0}
          idx = BOUNDS.index { |b| value <= b } || BOUNDS.size
          buckets[idx] += 1
          @series[key] = {buckets, count + 1, sum + value}
        end
      end
    end

    @@counters = {} of String => Counter
    @@histograms = {} of String => Histogram
    @@exporter : Exporter?
    @@enabled = false
    @@sample_rate = 1.0
    @@start = Time.utc

    def self.counter(name : String, unit : String = "1") : Counter
      @@counters[name] ||= Counter.new(name, unit)
    end

    def self.histogram(name : String, unit : String = "s") : Histogram
      @@histograms[name] ||= Histogram.new(name, unit)
    end

    def self.enabled? : Bool
      @@enabled || !ENV["OTEL_EXPORTER_OTLP_ENDPOINT"]?.nil? || Silth.config.bool("telemetry.enabled", false)
    end

    def self.exporter : Exporter?
      @@exporter
    end

    def self.boot : Nil
      return unless enabled?
      @@enabled = true
      config = Silth.config
      endpoint = ENV["OTEL_EXPORTER_OTLP_ENDPOINT"]? || config.string("telemetry.endpoint", "http://localhost:4318")
      service = ENV["OTEL_SERVICE_NAME"]? || config.string("telemetry.service_name", config.string("app.name", "silth-app"))
      @@sample_rate = config.float("telemetry.sample_rate", 1.0)
      headers = config.hash("telemetry.headers")
      @@exporter = Exporter.new(endpoint, service, headers)
      Instrument.subscribe do |event|
        case event
        when Instrument::Query
          if parent = Fiber.current.silth_span
            span = Span.new(event.sql.split(' ', 2).first.upcase, Kind::Client, parent.trace_id, parent.span_id, parent.sampled?, event.at - event.duration)
            span.set("db.system.name", DB[event.connection]?.try(&.dialect.name) || "unknown")
            span.set("db.query.text", event.sql[0, 2000])
            span.finish(event.at)
          end
          histogram("db.client.operation.duration").record(event.duration.total_seconds, {"db.connection" => event.connection})
        when Instrument::HTTPCall
          histogram("http.client.request.duration").record(event.duration.total_seconds, {"http.request.method" => event.method, "http.response.status_code" => event.status.to_s})
        when Instrument::Job
          counter("silth.jobs").add(1, {"job" => event.name, "status" => event.status})
        end
      end
      Silth.app.on_shutdown { @@exporter.try &.flush }
      Log.info { "OpenTelemetry export enabled → #{endpoint} (service #{service})" }
    end

    def self.current : Span?
      Fiber.current.silth_span
    end

    # Starts a span (child of the current one) for the block.
    def self.trace(name : String, kind : Kind | Symbol = Kind::Internal, attributes = {} of String => String, &)
      unless @@enabled
        return yield Span.new(name, Kind::Internal, "", nil, false)
      end
      kind_value = kind.is_a?(Symbol) ? (Kind.parse?(kind.to_s) || Kind::Internal) : kind
      parent = Fiber.current.silth_span
      span = if parent
               Span.new(name, kind_value, parent.trace_id, parent.span_id, parent.sampled?)
             else
               Span.new(name, kind_value, Random::Secure.hex(16), nil, Random.rand < @@sample_rate)
             end
      attributes.each { |k, v| span.set(k, v) }
      Fiber.current.silth_span = span
      begin
        yield span
      rescue ex
        span.record_exception(ex)
        raise ex
      ensure
        span.finish
        Fiber.current.silth_span = parent
      end
    end

    # Adds `traceparent` to outgoing HTTP headers.
    def self.inject(headers : HTTP::Headers) : Nil
      if span = Fiber.current.silth_span
        headers["traceparent"] = span.traceparent
      end
    end

    # Parses an incoming `traceparent` header.
    def self.extract(header : String?) : {String, String, Bool}?
      return nil unless header
      parts = header.split('-')
      return nil unless parts.size == 4 && parts[1].size == 32 && parts[2].size == 16
      {parts[1], parts[2], parts[3] == "01"}
    end

    # Server span per request named after the route pattern.
    class Middleware < Silth::Middleware
      def call(ctx : Context, chain : Chain) : Nil
        remote = Telemetry.extract(ctx.header("traceparent"))
        span = if r = remote
                 Span.new(ctx.method, Kind::Server, r[0], r[1], r[2])
               else
                 Span.new(ctx.method, Kind::Server, Random::Secure.hex(16), nil, Random.rand < Silth.config.float("telemetry.sample_rate", 1.0))
               end
        Fiber.current.silth_span = span
        ctx.response.headers["traceparent"] = span.traceparent
        ::Log.with_context(trace_id: span.trace_id, span_id: span.span_id) do
          chain.next(ctx)
        end
      rescue ex
        span.try &.record_exception(ex)
        raise ex
      ensure
        if s = span
          route = ctx.route.try(&.path)
          s.name = route ? "#{ctx.method} #{route}" : ctx.method
          s.set("http.request.method", ctx.method).set("url.path", ctx.path).set("http.response.status_code", ctx.status.to_i64)
          s.set("http.route", route) if route
          s.set("client.address", ctx.remote_ip)
          s.set("user_agent.original", ctx.user_agent || "")
          s.status_code = 2 if ctx.status >= 500
          s.finish
          Telemetry.histogram("http.server.request.duration").record(s.duration.total_seconds,
            {"http.request.method" => ctx.method, "http.route" => route || "", "http.response.status_code" => ctx.status.to_s})
        end
        Fiber.current.silth_span = nil
      end
    end

    # --- encoding helpers ----------------------------------------------------

    def self.nanos(t : Time) : String
      (t.to_unix.to_i128 * 1_000_000_000 + t.nanosecond).to_s
    end

    def self.attributes_json(attrs : Hash(String, AttrValue)) : String
      JSON.build do |j|
        j.array do
          attrs.each do |k, v|
            j.object do
              j.field "key", k
              j.field "value" do
                j.object do
                  case v
                  when String  then j.field "stringValue", v
                  when Int64   then j.field "intValue", v.to_s
                  when Float64 then j.field "doubleValue", v
                  when Bool    then j.field "boolValue", v
                  end
                end
              end
            end
          end
        end
      end
    end

    def self.metrics_json(resource : String) : String?
      return nil if @@counters.empty? && @@histograms.empty?
      now = nanos(Time.utc)
      start = nanos(@@start)
      JSON.build do |j|
        j.object do
          j.field "resourceMetrics" do
            j.array do
              j.object do
                j.field("resource") { j.raw(resource) }
                j.field "scopeMetrics" do
                  j.array do
                    j.object do
                      j.field("scope") { j.object { j.field "name", "silth" } }
                      j.field "metrics" do
                        j.array do
                          @@counters.each_value do |c|
                            j.object do
                              j.field "name", c.name
                              j.field "unit", c.unit
                              j.field "sum" do
                                j.object do
                                  j.field "aggregationTemporality", 2
                                  j.field "isMonotonic", true
                                  j.field "dataPoints" do
                                    j.array do
                                      c.values.each do |key, value|
                                        j.object do
                                          j.field("attributes") { j.raw(attributes_json(Hash(String, String).from_json(key).transform_values(&.as(AttrValue)))) }
                                          j.field "startTimeUnixNano", start
                                          j.field "timeUnixNano", now
                                          j.field "asDouble", value
                                        end
                                      end
                                    end
                                  end
                                end
                              end
                            end
                          end
                          @@histograms.each_value do |h|
                            j.object do
                              j.field "name", h.name
                              j.field "unit", h.unit
                              j.field "histogram" do
                                j.object do
                                  j.field "aggregationTemporality", 2
                                  j.field "dataPoints" do
                                    j.array do
                                      h.series.each do |key, (buckets, count, sum)|
                                        j.object do
                                          j.field("attributes") { j.raw(attributes_json(Hash(String, String).from_json(key).transform_values(&.as(AttrValue)))) }
                                          j.field "startTimeUnixNano", start
                                          j.field "timeUnixNano", now
                                          j.field "count", count.to_s
                                          j.field "sum", sum
                                          j.field "bucketCounts", buckets.map(&.to_s)
                                          j.field "explicitBounds", Histogram::BOUNDS
                                        end
                                      end
                                    end
                                  end
                                end
                              end
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
