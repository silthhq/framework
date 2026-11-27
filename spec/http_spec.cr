require "./spec_helper"

describe "HTTP stack" do
  it "routes to closures, constraints and globs" do
    client.get("/ping").body.should eq("pong")
    client.get("/items/12").body.should eq("item 12")
    client.get("/items/ab").status.should eq(404)
    client.get("/files/a/b.txt").body.should eq("a/b.txt")
  end

  it "renders escaped templates inside layouts" do
    res = client.get("/hello")
    res.should be_ok
    res.body.should contain("Hello &lt;Ada&gt;")
    res.body.should contain("<b>ok</b>")
    res.body.should contain("<li>a</li><li>b</li>")
    res.body.should contain("<title>Default</title>")
  end

  it "runs filters, creates records and redirects" do
    client.get("/notes").header("X-Filtered").should eq("yes")
    res = client.post("/notes", form: {"note[title]" => "Created via form"})
    res.should be_redirect
    res.location.not_nil!.should start_with("/notes/")
    Note.where(title: "Created via form").exists?.should be_true
    client.post("/notes", form: {"note[title]" => ""}).status.should eq(422)
  end

  it "binds forms to models" do
    note = Note.create!(title: "Form")
    client.get("/notes/#{note.id}").body.should contain(%(name="note[title]" id="note_title" value="Form"))
  end

  it "maps errors to statuses and problem+json" do
    client.get("/nope").status.should eq(404)
    client.get("/boom").status.should eq(500)
    res = client.get_json("/nope")
    res.json["status"].as_i.should eq(404)
    client.delete("/ping").status.should eq(405)
  end

  it "protects authenticated scopes" do
    client.get("/admin").status.should eq(302)
    client.get_json("/api/notes").should be_ok
  end
end

describe Silth::Component do
  it "renders props and slots" do
    view = NotesController.new(Silth::Context.new(HTTP::Server::Context.new(HTTP::Request.new("GET", "/"), HTTP::Server::Response.new(IO::Memory.new))))
    view.component(CardComponent, title: "<Hi>").value.should eq(%(<section class="card"><h2>&lt;Hi&gt;</h2></section>\n))
  end
end

describe Silth::LiveComponent do
  it "round trips signed state and dispatches actions" do
    live = CounterLive.new(count: 2)
    html = live.render_live
    state = html.match(/data-silth-state="([^"]+)"/).not_nil![1]
    message = JSON.parse({c: "CounterLive", s: HTML.unescape(state), a: "add", args: [5], m: {step: 3}, id: "x"}.to_json)
    response = JSON.parse(Silth::Live.process(message, nil))
    response["html"].as_s.should contain(">7<")
    tampered = JSON.parse({c: "CounterLive", s: "bad--sig", a: "increment"}.to_json)
    expect_raises(Silth::Forbidden) { Silth::Live.process(tampered, nil) }
  end
end

describe Silth::Concurrency do
  it "maps in parallel preserving order" do
    Silth::Concurrency.map([3, 1, 2], workers: 3) { |n| sleep (n * 5).milliseconds; n * 10 }.should eq([30, 10, 20])
    expect_raises(Silth::Concurrency::Timeout) { Silth::Concurrency.timeout(10.milliseconds) { sleep 1.second; 1 } }
  end
end

describe Silth::RateLimit do
  it "limits hits per window" do
    3.times { Silth::RateLimit.hit("spec", 3, 1.minute).allowed?.should be_true }
    Silth::RateLimit.hit("spec", 3, 1.minute).allowed?.should be_false
  end
end

class SpecJob < Silth::Job
  class_property ran = 0
  getter amount : Int32

  def initialize(@amount)
  end

  def perform : Nil
    SpecJob.ran += amount
  end
end

class SpecMail < Silth::Mail
  def build : Nil
    to "ada@example.com", "Ada"
    subject "Bienvenue ✨"
    html "<p>Hello</p>"
  end
end

describe "background services" do
  it "runs jobs, sends mails and stores files" do
    SpecJob.new(4).dispatch
    SpecJob.ran.should eq(4)
    Silth::Queue.fake
    SpecJob.new(1).dispatch
    Silth::Queue.pushed?(SpecJob).should be_true
    SpecMail.new.deliver
    Silth::Mailer.sent.last.subject_line.should eq("Bienvenue ✨")
    Silth::Mailer.sent.last.to_mime.should contain("=?UTF-8?B?")
    disk = Silth::Storage.fake
    disk.put("a/b.txt", "hi")
    Silth.storage.read("a/b.txt").should eq("hi")
    Silth.cache.fetch("k", 1.minute) { "v" }.should eq("v")
    Silth.cache.get("k").should eq("v")
  end

  it "signs S3 presigned URLs" do
    disk = Silth::Storage::S3Disk.new("bucket", "us-east-1", "AKID", "secret")
    url = disk.temporary_url("reports/q4.pdf", 10.minutes)
    url.should contain("X-Amz-Signature=")
    url.should contain("bucket.s3.us-east-1.amazonaws.com/reports/q4.pdf")
  end
end

describe "Silth::HTTPClient multipart" do
  it "sends fields and files, and reads binary responses" do
    pdf = Bytes[0x25, 0x50, 0x44, 0x46, 0xFF, 0x00, 0x0A]
    Silth::HTTPClient.fake("gotenberg.test/*") { |r| Silth::HTTPClient::Response.new(200, String.new(pdf), HTTP::Headers{"Content-Type" => "application/pdf"}, r.resource) }
    response = Silth::HTTPClient.new.base_url("http://gotenberg.test").post("/forms/chromium/convert/html", multipart: [
      {"files", Silth::HTTPClient::File.new("index.html", "<h1>Invoice</h1>", "text/html")},
      {"files", Silth::HTTPClient::File.new("logo.png", Bytes[0x89, 0x50, 0x00], "image/png")},
      {"paperWidth", "8.27"},
    ] of {String, Silth::HTTPClient::Part})
    response.bytes.should eq(pdf)
    request = Silth::HTTPClient.recorded.last
    request.headers["Content-Type"].should start_with("multipart/form-data; boundary=silth-")
    parts = [] of {String, String?, String}
    HTTP::FormData.parse(request) { |part| parts << {part.name, part.filename, part.body.gets_to_end} }
    parts.should eq([{"files", "index.html", "<h1>Invoice</h1>"}, {"files", "logo.png", String.new(Bytes[0x89, 0x50, 0x00])}, {"paperWidth", nil, "8.27"}])
  ensure
    Silth::HTTPClient.reset_fakes
  end
end

describe Silth::ContentDisposition do
  it "keeps an ASCII fallback and the exact UTF-8 name" do
    Silth::ContentDisposition.format("attachment", "Facture été.pdf")
      .should eq(%(attachment; filename="Facture _t_.pdf"; filename*=UTF-8''Facture%20%C3%A9t%C3%A9.pdf))
    Silth::ContentDisposition.format("inline", %(a"b.txt)).should eq(%(inline; filename="a_b.txt"; filename*=UTF-8''a%22b.txt))
  end
end

describe Silth::SecureHeadersMiddleware do
  it "adds, replaces and removes headers from the configuration" do
    middleware = Silth::SecureHeadersMiddleware.new(extra: {"X-Frame-Options" => "DENY", "Permissions-Policy" => "", "X-Download-Options" => "noopen"})
    raw = HTTP::Server::Context.new(HTTP::Request.new("GET", "/"), HTTP::Server::Response.new(IO::Memory.new))
    ctx = Silth::Context.new(raw)
    middleware.call(ctx, Silth::Chain.new([] of Silth::Middleware, Silth::Endpoint.new { |_| nil }))
    ctx.response.headers["X-Frame-Options"].should eq("DENY")
    ctx.response.headers["X-Download-Options"].should eq("noopen")
    ctx.response.headers.has_key?("Permissions-Policy").should be_false
  end
end
