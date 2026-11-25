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
