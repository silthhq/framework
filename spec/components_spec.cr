require "./spec_helper"

class PanelComponent < Silth::Component
  template "spec/fixtures/views/panel.html.ecr"
end

class PanelPageComponent < Silth::Component
  prop title : String = "Stats"
  prop with_footer : Bool = false
  template "spec/fixtures/views/panel_page.html.ecr"
end

class LegacySlotComponent < Silth::Component
  template "spec/fixtures/views/legacy_slot.html.ecr"
end

class TodoListLive < Silth::LiveComponent
  prop items : Array(String) = [] of String
  prop removed : Array(String) = [] of String
  template "spec/fixtures/views/todo_list.html.ecr"

  action def forget(label : String)
    @removed = removed + [label]
  end
end

class TodoLive < Silth::LiveComponent
  prop label : String
  prop clicks : Int32 = 0
  template "spec/fixtures/views/todo.html.ecr"

  action def remove
    @clicks = clicks + 1
    notify_parent("forget", label)
  end
end

class AvatarLive < Silth::LiveComponent
  prop avatar : Silth::Live::Upload?, writable: true
  prop stored : String?
  template "spec/fixtures/views/avatar.html.ecr"

  action def save
    if file = avatar
      @stored = file.store("avatars", "memory")
      @avatar = nil
    end
  end
end

module ComponentSpec
  # The JSON message the browser sends for *component* (state taken from its HTML).
  def self.message(html : String, id : String, **extra) : JSON::Any
    root = html.match(/id="#{id}" data-silth-live="([^"]+)" data-silth-state="([^"]+)"/).not_nil!
    JSON.parse({c: root[1], s: HTML.unescape(root[2]), id: id}.merge(extra).to_json)
  end

  def self.multipart(filename : String, content_type : String, content : String) : {String, HTTP::Headers}
    io = IO::Memory.new
    boundary = "silth-spec"
    HTTP::FormData.build(io, boundary) do |form|
      form.file("file", IO::Memory.new(content), HTTP::FormData::FileMetadata.new(filename: filename), HTTP::Headers{"Content-Type" => content_type})
    end
    {io.to_s, HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=#{boundary}", "Sec-Fetch-Site" => "same-origin"}}
  end
end

describe "component slots" do
  it "fills named slots from the caller's block" do
    PanelPageComponent.new(title: "<Q4>").render.should eq(%(<article><header><h1>&lt;Q4&gt;</h1></header><p>Body</p></article>\n))
    PanelPageComponent.new(with_footer: true).render.should contain(%(<footer><small>Footer</small></footer>))
  end

  it "keeps blocks without a parameter as the default slot" do
    LegacySlotComponent.new.render.should eq(%(<section class="card"><h2>legacy</h2><em>old style</em></section>\n))
  end
end

describe "nested live components" do
  it "gives children stable ids and a props fingerprint" do
    parent = TodoListLive.new(items: ["milk", "eggs"])
    parent.live_id = "list"
    html = parent.render_live
    html.should contain(%(id="list-milk"))
    html.should contain(%(id="list-eggs"))
    first = html.match(/id="list-milk"[^>]*data-silth-props="([0-9a-f]+)"/).not_nil![1]
    again = parent.render_live.match(/id="list-milk"[^>]*data-silth-props="([0-9a-f]+)"/).not_nil![1]
    again.should eq(first)
  end

  it "runs child actions on their own and calls the parent back" do
    parent = TodoListLive.new(items: ["milk"])
    parent.live_id = "list"
    html = parent.render_live
    response = JSON.parse(Silth::Live.process(ComponentSpec.message(html, "list-milk", a: "remove"), nil))
    response["id"].should eq("list-milk")
    response["html"].as_s.should contain("milk (1)")
    response["parent"].should eq(JSON.parse(%([{"a": "forget", "args": ["milk"]}])))

    parent_call = ComponentSpec.message(html, "list", a: "forget", args: ["milk"])
    JSON.parse(Silth::Live.process(parent_call, nil))["html"].as_s.should contain(%(<span class="removed">milk</span>))
  end
end

describe Silth::Live::Upload do
  it "uploads to a temporary file and hands the component a signed token" do
    Silth::Storage.register("memory", Silth::Storage::MemoryDisk.new)
    body, headers = ComponentSpec.multipart("me.png", "image/png", "PNGDATA")
    response = client.request("POST", Silth::Live::Upload::PATH, body, headers)
    response.status.should eq(200)
    token = response.json["token"].as_s

    preview = client.request("GET", "#{Silth::Live::Upload::PATH}?t=#{URI.encode_www_form(token)}", nil, HTTP::Headers{"Sec-Fetch-Site" => "same-origin"})
    preview.body.should eq("PNGDATA")
    preview.headers["Content-Type"].should eq("image/png")

    live = AvatarLive.new
    live.live_id = "avatar"
    html = JSON.parse(Silth::Live.process(ComponentSpec.message(live.render_live, "avatar", m: {avatar: token}), nil))["html"].as_s
    html.should contain(%(alt="me.png"))

    state = JSON.parse(Silth::Live.process(ComponentSpec.message(live.render_live, "avatar", m: {avatar: token}, a: "save"), nil))
    stored = Silth.verifier("live").verify?(state["s"].as_s).try { |s| JSON.parse(s)["stored"].as_s }.not_nil!
    stored.should start_with("avatars/")
    Silth::Storage.disk("memory").read(stored).should eq("PNGDATA")
  end

  it "rejects forged tokens" do
    expect_raises(Silth::Forbidden) { Silth::Live::Upload.from_token("forged--token") }
  end
end

class BadgeComponent < Silth::Component
  prop label : String
  prop count : Int32 = 0
  prop muted : Bool = false
  prop hint : String? = nil
  prop tags : Array(String) = [] of String
  template "spec/fixtures/views/card.html.ecr"

  def title : String
    "#{label} (#{count})#{muted ? " muted" : ""}#{hint ? " #{hint}" : ""}"
  end
end

class BadgeComponentPreview < Silth::ComponentPreview
  description "Counters next to a label."

  def default : Silth::Component
    BadgeComponent.new(label: "Inbox", count: 3)
  end

  def in_a_panel : Silth::Component
    PanelComponent.new.with_slots(content: "<p>Body</p>", footer: %(<a href="/all">All</a>))
  end

  def live_counter : Silth::Component
    CounterLive.new(count: 5)
  end
end

describe Silth::ComponentPreview do
  it "lists scenarios and builds their components" do
    Silth::ComponentPreview.all.should contain({"BadgeComponentPreview", ["default", "in_a_panel", "live_counter"]})
    Silth::ComponentPreview.description_of("BadgeComponentPreview").should eq("Counters next to a label.")
    Silth::ComponentPreview.build("BadgeComponentPreview", "default").not_nil!.render.should contain("Inbox (3)")
    Silth::ComponentPreview.build("BadgeComponentPreview", "nope").should be_nil
  end

  it "describes props, edits the scalar ones and fills slots from code" do
    badge = BadgeComponent.new(label: "Inbox", count: 3)
    specs = badge.prop_specs.to_h { |s| {s.name, s} }
    {specs["label"].type, specs["label"].value, specs["label"].default, specs["label"].editable}.should eq({"String", %("Inbox"), "nil", true})
    {specs["hint"].nilable, specs["tags"].editable, specs["count"].default}.should eq({true, false, "0"})
    badge.assign_prop_text("count", "12").should be_true
    badge.assign_prop_text("muted", "true").should be_true
    badge.assign_prop_text("hint", "new").should be_true
    badge.assign_prop_text("count", "many").should be_false
    badge.assign_prop_text("tags", "x").should be_false
    badge.render.should contain("Inbox (12) muted new")
    badge.assign_prop_text("hint", "").should be_true # nilable: empty means nil
    badge.hint.should be_nil

    panel = PanelComponent.new.with_slots(content: "<p>Body</p>", footer: %(<a href="/all">All</a>))
    panel.render.should eq(%(<article><header></header><p>Body</p><footer><a href="/all">All</a></footer></article>))
    panel.filled_slots.should eq(["content", "footer"])
    Silth::Profiler::ComponentViewer.usage(badge).should eq(%(<%= component BadgeComponent, label: "Inbox", count: 12, muted: true %>))
    Silth::Profiler::ComponentViewer.usage(panel).should eq("<% component PanelComponent do |c| %>\n  <% c.slot :footer do %>…<% end %>\n  …\n<% end %>")
  end

  it "serves the components section and the scenario frames" do
    pages = {
      "/_silth/profiler/components"                                                 => "BadgeComponent",
      "/_silth/profiler/components/BadgeComponentPreview/default?w=375&p[count]=7" => "width:375px",
      "/_silth/profiler/components/BadgeComponentPreview/default/frame?p[count]=7" => "Inbox (7)",
      "/_silth/profiler/components/BadgeComponentPreview/live_counter/frame"      => %(data-silth-live="CounterLive"),
    }
    pages.each do |path, text|
      io = IO::Memory.new
      ctx = Silth::Context.new(HTTP::Server::Context.new(HTTP::Request.new("GET", path), HTTP::Server::Response.new(io)))
      Silth::Profiler::Dashboard.serve(ctx)
      ctx.response.close
      io.to_s.should contain(text)
    end
  end
end
