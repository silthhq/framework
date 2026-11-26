require "./spec_helper"

module ProfilerSpec
  def self.context(path : String) : {Silth::Context, IO::Memory}
    io = IO::Memory.new
    {Silth::Context.new(HTTP::Server::Context.new(HTTP::Request.new("GET", path), HTTP::Server::Response.new(io))), io}
  end

  # A profile shaped like a real request: queries before and inside the
  # action, a template, a log warning and translation lookups.
  def self.profile : Silth::Profiler::Profile
    p = Silth::Profiler::Profile.new(Time.instant - 50.milliseconds)
    p.method = "GET"
    p.path = "/posts/1"
    p.url = "/posts/1?x=<b>"
    p.status = 200
    p.handler = "PostsController#show"
    p.locale = "fr"
    rec = ->(e : Silth::Instrument::Event) { Silth::Profiler.record(e, p) }
    rec.call(Silth::Instrument::Query.new("SELECT * FROM sessions WHERE id = ?", ["s1"], 1.millisecond, "primary", 1))
    rec.call(Silth::Instrument::Action.new("PostsController", "show"))
    2.times { rec.call(Silth::Instrument::Query.new("SELECT * FROM comments WHERE post_id = ?", ["1"], 0.5.milliseconds, "primary", 3)) }
    rec.call(Silth::Instrument::Render.new("src/views/posts/show.html.ecr", 2.milliseconds))
    rec.call(Silth::Instrument::Translation.new("posts.title", "fr", "found"))
    rec.call(Silth::Instrument::Translation.new("posts.title", "fr", "found"))
    rec.call(Silth::Instrument::Translation.new("posts.subtitle", "fr", "missing"))
    rec.call(Silth::Instrument::Cache.new("get", "post:1", true, "memory"))
    p.logs << Silth::Profiler::LogEntry.new("warn", "app", "Careful <now>", Time.utc, p.elapsed_ms)
    p.span("log", "Careful <now>", "app", level: "warn")
    rec.call(Silth::Instrument::Action.new("PostsController", "show", 5.milliseconds))
    p
  end
end

describe Silth::Profiler do
  it "records spans, translations and duplicated queries" do
    p = ProfilerSpec.profile
    p.queries.size.should eq(3)
    p.duplicated_queries.should eq(1)
    p.missing_translations.map(&.key).should eq(["posts.subtitle"])
    p.translations[{"fr", "posts.title"}].count.should eq(2)
    p.action_span.not_nil!.duration_ms.not_nil!.should be > 0
    p.before_action_ms.not_nil!.should be > 0
    p.spans.map(&.kind).should contain("view")
    p.entries.first.offset_ms.should_not be_nil
  end

  it "nests the timeline by containment" do
    span = ->(kind : String, label : String, start : Float64, ms : Float64?) { Silth::Profiler::Span.new(kind, label, "", start, ms, instant: ms.nil?) }
    p = Silth::Profiler::Profile.new
    p.method, p.url, p.duration_ms = "GET", "/posts/1", 50.0
    p.spans << span.call("db", "SELECT sessions", 1.0, 1.0)
    p.spans << span.call("controller", "PostsController#show", 5.0, 40.0)
    p.spans << span.call("db", "SELECT comments", 6.0, 0.5)
    p.spans << span.call("cache", "set comments", 6.2, nil)
    p.spans << span.call("db", "SELECT comments", 7.0, 0.5)
    p.spans << span.call("view", "posts/show.html.ecr", 10.0, 20.0)
    p.spans << span.call("db", "SELECT authors", 12.0, 1.0)
    p.spans << span.call("log", "Careful", 15.0, nil).tap(&.level=("warn"))
    rows = Silth::Profiler::Timeline.rows(p).map { |r| {r.span.label, r.depth} }
    rows.should eq([
      {"GET /posts/1", 0},
      {"Before the action", 1},
      {"SELECT sessions", 2},
      {"PostsController#show", 1},
      {"SELECT comments", 2},
      {"set comments", 2}, # during the query, not inside it
      {"SELECT comments", 2},
      {"posts/show.html.ecr", 2},
      {"SELECT authors", 3},
      {"Careful", 3},
      {"After the action", 1},
    ])
    html = Silth::Profiler::Timeline.render(p)
    html.should contain(%(class="s-tl-row k-log warn"))
    html.should contain(%(<i class="s-tl-bar" style="left:10.0%;width:80.0%"></i>)) # the action
  end

  it "renders a toolbar with hover panels, new-tab links and a folded mode" do
    p = ProfilerSpec.profile
    html = Silth::Profiler::Toolbar.render(p, "n0nce")
    html.should contain(%(<style nonce="n0nce">))
    html.should contain(%(<script nonce="n0nce">))
    html.should_not contain("overflow-x")
    html.should contain(%(class="stb-pop"))
    html.should contain(%(href="/_silth/profiler/#{p.token}?panel=queries" target="_blank" rel="noopener"))
    html.should contain(%(<code class="warn">posts.subtitle</code>))
    html.should contain("possible N+1")
    html.should contain(%(class="stb-fab"))
    html.should contain("/posts/1?x=&lt;b&gt;")
    html.should contain(%(<div class="stb-item stb-xhr" tabindex="-1" hidden>)) # sub-requests, filled in the browser
    html.should contain(%(res.headers.get("X-Silth-Profile")))
  end

  it "profiles live component actions as requests of their own" do
    Silth::Profiler.enabled = true
    state = Silth.verifier("live").generate(%({"count":1,"step":2}))
    body = Silth::Live.process(JSON.parse({c: "CounterLive", s: state, a: "increment", id: "c1"}.to_json), nil)
    info = JSON.parse(body)["profile"]
    info["label"].should eq("CounterLive#increment")
    live = Silth::Profiler.find(info["token"].as_s).not_nil!
    {live.method, live.status, live.handler}.should eq({"LIVE", 200, "CounterLive#increment"})

    expect_raises(Silth::BadRequest) do
      Silth::Live.process(JSON.parse({c: "CounterLive", s: state, a: "nope", id: "c1"}.to_json), nil)
    end
    failed = Fiber.current.silth_failed_live_profile.not_nil!
    {failed.status, failed.exceptions.first.name}.should eq({400, "Silth::BadRequest"})
  ensure
    Fiber.current.silth_failed_live_profile = nil
    Silth::Profiler.clear
  end

  it "serves the dashboard panels" do
    p = ProfilerSpec.profile
    Silth::Profiler.store(p)
    {"timeline" => "s-timeline", "queries" => "possible N+1", "logs" => "Careful &lt;now&gt;",
     "translations" => "posts.subtitle", "events" => "get post:1", "request" => "PostsController#show"}.each do |panel, text|
      ctx, io = ProfilerSpec.context("/_silth/profiler/#{p.token}?panel=#{panel}")
      Silth::Profiler::Dashboard.serve(ctx)
      ctx.response.close
      body = io.to_s
      body.should contain(%(class="s-app"))
      body.should contain(text)
      body.should contain(%(class="active">#{Silth::Profiler::Dashboard::PANELS[panel]}))
    end

    ctx, io = ProfilerSpec.context("/_silth/profiler")
    Silth::Profiler::Dashboard.serve(ctx)
    ctx.response.close
    io.to_s.should contain(%(href="/_silth/profiler/#{p.token}"))

    ctx, io = ProfilerSpec.context("/_silth/profiler/nope")
    Silth::Profiler::Dashboard.serve(ctx)
    ctx.response.close
    io.to_s.should contain("404 Not Found")
  ensure
    Silth::Profiler.clear
  end
end

module ProfilerSpec
  # Records the instrumentation of the current fiber into its profile, as in development.
  class_getter subscribed : Bool = begin
    Silth::Profiler.enabled = true
    Silth::Profiler.boot
    true
  end

  def self.with_config(yaml : String, &)
    previous = Silth.config
    Silth.config = Silth::Config.new(YAML.parse(yaml))
    begin
      yield
    ensure
      Silth.config = previous
    end
  end
end

describe "Profiler query sources" do
  it "finds the first frame of application code" do
    frames = ["src/silth/db.cr:250:13 in 'query'", "lib/silth/src/silth/orm/query.cr:40:5 in 'to_a'",
              "/usr/share/crystal/src/array.cr:10:3 in 'each'", "#{Dir.current}/src/views/posts/index.html.ecr:8:3 in 'to_s'",
              "src/controllers/posts_controller.cr:12:5 in 'index'"]
    source = Silth::Profiler.app_source(frames).not_nil!
    {source.file, source.line, source.method}.should eq({"src/views/posts/index.html.ecr", 8, "to_s"})
    Silth::Profiler.app_source(["src/silth/db.cr:1:1 in 'x'", "?? in '??'"]).should be_nil
  end

  it "ties each query to the line that ran it and groups the repeats (N+1)" do
    ProfilerSpec.subscribed.should be_true
    p = Silth::Profiler::Profile.new
    p.method, p.url, p.status = "GET", "/notes", 200
    Fiber.current.silth_profile = p
    line = __LINE__ + 1
    3.times { |i| Note.where(title: "n+1 #{i}").to_a }
    Note.count
    Fiber.current.silth_profile = nil
    p.queries.size.should eq(4)
    p.queries.first.source.not_nil!.to_s.should eq("spec/profiler_spec.cr:#{line}")
    repeat = p.repeated_queries.first
    {repeat.count, repeat.source.try(&.line)}.should eq({3, line})
    p.spans.find(&.kind.==("db")).not_nil!.source.should eq(p.queries.first.source)

    Silth::Profiler.store(p)
    ctx, io = ProfilerSpec.context("/_silth/profiler/#{p.token}?panel=queries")
    Silth::Profiler::Dashboard.serve(ctx)
    ctx.response.close
    io.to_s.should contain("spec/profiler_spec.cr:#{line}")
    io.to_s.should contain("from ")
  ensure
    Fiber.current.silth_profile = nil
    Silth::Profiler.clear
  end
end

describe Silth::Profiler::Editor do
  it "links file:line to the configured editor" do
    ProfilerSpec.with_config("profiler:\n  editor: vscode") do
      Silth::Profiler::Editor.url("src/app.cr", 3).should eq("vscode://file#{Dir.current}/src/app.cr:3")
      Silth::Profiler::Editor.link("src/app.cr", 3).should contain(%(<a class="s-src" href="vscode://file#{Dir.current}/src/app.cr:3"))
    end
    ProfilerSpec.with_config("profiler:\n  editor: zed\n  editor_root: /home/me/blog") do
      Silth::Profiler::Editor.url("#{Dir.current}/src/my app.cr", 7).should eq("zed://file/home/me/blog/src/my%20app.cr:7")
    end
    ProfilerSpec.with_config("profiler:\n  editor: \"x-ide://open?f={file}&l={line}\"") do
      Silth::Profiler::Editor.url("/abs/file.cr", 9).should eq("x-ide://open?f=/abs/file.cr&l=9")
    end
    ProfilerSpec.with_config("profiler:\n  editor: none") do
      Silth::Profiler::Editor.url("src/app.cr", 3).should be_nil
      Silth::Profiler::Editor.link("src/app.cr", 3).should eq(%(<code class="s-src">src/app.cr:3</code>))
    end
  end
end

describe Silth::Profiler::Storage do
  it "keeps profiles across restarts in a SQLite file" do
    path = "spec/tmp/profiler/profiles.sqlite3"
    FileUtils.rm_rf("spec/tmp/profiler")
    Silth::Profiler.clear
    Silth::Profiler.persist(path)
    p = ProfilerSpec.profile
    p.duration_ms = 12.5
    Silth::Profiler.store(p)
    Silth::Profiler.stop_persisting

    Silth::Profiler.clear              # a new process: empty memory
    Silth::Profiler.persist(path)      # boot with persist: true
    loaded = Silth::Profiler.find(p.token).not_nil!
    {loaded.method, loaded.url, loaded.status, loaded.duration_ms}.should eq({"GET", "/posts/1?x=<b>", 200, 12.5})
    loaded.queries.size.should eq(3)
    loaded.translations[{"fr", "posts.title"}].count.should eq(2)
    loaded.spans.map(&.kind).should eq(p.spans.map(&.kind))
    loaded.logs.first.message.should eq("Careful <now>")
    Silth::Profiler::Timeline.render(loaded).should contain("PostsController#show")

    Silth::Profiler.clear
    Silth::Profiler::Storage.new(path).load(10).should be_empty
  ensure
    Silth::Profiler.stop_persisting
    Silth::Profiler.clear
    FileUtils.rm_rf("spec/tmp/profiler")
  end
end

describe Silth::Profiler::Budget do
  it "resolves the handler's, then the route's, then the global budget" do
    ProfilerSpec.with_config(%(profiler:\n  budget_ms: 300\n  budgets:\n    "GET /notes": 120\n    "NotesController#show": 80)) do
      Silth::Profiler::Budget.for("GET", "/notes/:id", "NotesController#show").should eq(80.0)
      Silth::Profiler::Budget.for("GET", "/notes", "NotesController#index").should eq(120.0)
      Silth::Profiler::Budget.for("GET", "/hello", "NotesController#hello").should eq(300.0)
    end
    Silth::Profiler::Budget.for("GET", "/hello", "NotesController#hello").should be_nil
  end

  it "flags slow requests in the toolbar and reports them in the test run" do
    p = ProfilerSpec.profile
    p.duration_ms = 420.0
    p.budget_ms = 300.0
    p.over_budget?.should be_true
    html = Silth::Profiler::Toolbar.render(p, nil)
    html.should contain(%(<div class="stb-item  err" tabindex="-1"><a href="/_silth/profiler/#{p.token}?panel=timeline"))
    html.should contain("300 ms, exceeded by 120 ms")

    ProfilerSpec.with_config("profiler:\n  budget_ms: 0.000001") do
      Silth::Testing.budget_reports.clear
      Silth::Testing.client.get("/hello")
      report = Silth::Testing.budget_reports.first
      {report.route, report.source.try(&.starts_with?("spec/profiler_spec.cr"))}.should eq({"GET /hello", true})
      output = IO::Memory.new
      Silth::Testing.print_budget_reports(output)
      output.to_s.should contain("Performance budgets exceeded")
      ENV["SILTH_BUDGETS"] = "strict"
      expect_raises(Spec::AssertionFailed, /over its 0.0 ms budget \(GET \/hello\)/) { Silth::Testing.client.get("/hello") }
    ensure
      ENV.delete("SILTH_BUDGETS")
      Silth::Testing.budget_reports.clear
    end
  end
end
