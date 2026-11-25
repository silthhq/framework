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
