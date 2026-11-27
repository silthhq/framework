require "./spec_helper"

describe Silth::Inflector do
  it "pluralizes and singularizes" do
    Silth::Inflector.pluralize("category").should eq("categories")
    Silth::Inflector.pluralize("person").should eq("people")
    Silth::Inflector.singularize("statuses").should eq("status")
    Silth::Inflector.tableize("BlogPost").should eq("blog_posts")
    Silth::Inflector.classify("blog_posts").should eq("BlogPost")
    Silth::Inflector.parameterize("Héllo, Wörld!").should eq("hello-world")
  end
end

describe Silth::Config do
  it "interpolates env vars and merges when@env blocks" do
    ENV["SILTH_SPEC_PORT"] = "4242"
    config = Silth::Config.new(YAML::Any.new({YAML::Any.new("app") => Silth::Config.parse(<<-YAML, "production")}))
      name: Silth
      port: ${SILTH_SPEC_PORT}
      url: ${MISSING_VAR:-http://x.test}
      debug: true
      when@production:
        debug: false
      YAML
    config.string("app.name").should eq("Silth")
    config.int("app.port", 0).should eq(4242)
    config.string("app.url").should eq("http://x.test")
    config.bool("app.debug").should be_false
  end
end

describe Silth::Dotenv do
  it "parses quoted values and expansions" do
    vars = Silth::Dotenv.parse(%(A=1\nB="two words" # comment\nexport C='lit ${A}'\nD=${A}-x\n))
    vars["B"].should eq("two words")
    vars["C"].should eq("lit ${A}")
    vars["D"].should eq("1-x")
  end
end

describe Silth::Crypto do
  it "encrypts, signs and hashes" do
    enc = Silth::Encryptor.new("secret")
    enc.decrypt(enc.encrypt("hello")).should eq("hello")
    enc.decrypt?("tampered.x.y").should be_nil
    v = Silth::MessageVerifier.new("secret")
    v.verify?(v.generate("x", purpose: "a"), purpose: "a").should eq("x")
    v.verify?(v.generate("x", purpose: "a"), purpose: "b").should be_nil
    Silth::Crypto.verify_password("pw", Silth::Crypto.hash_password("pw", 4)).should be_true
    Silth::Crypto.uuid7.size.should eq(36)
  end

  it "signs and verifies JWTs with HS384 and HS512" do
    token = Silth::JWT.encode({"sub" => "42"}, "k", algorithm: "HS512")
    JSON.parse(String.new(Base64.decode(token.split('.')[0])))["alg"].should eq("HS512")
    Silth::JWT.decode(token, "k")["sub"].should eq("42")
    Silth::JWT.decode(Silth::JWT.encode({"sub" => "1"}, "k", algorithm: "HS384"), "k")["sub"].should eq("1")
    expect_raises(Silth::JWT::Invalid, /Unsupported algorithm/) { Silth::JWT.decode(token, "k", algorithms: ["HS256"]) }
    # Signed by another implementation (Python's hmac, as Rust's jsonwebtoken does)
    foreign = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzUxMiJ9.eyJwaWQiOiIxMTExMTExMS0yMjIyLTMzMzMtNDQ0NC01NTU1NTU1NTU1NTUiLCJleHAiOjQxMDI0NDQ4MDAsImNsYWltcyI6e319.YVglcxDh_x04lQieoaMBXaCDi8JQ2lkItAXfzx3AYNKZgzMQ76JjF8mHgxccXiLIogucpT7EXVq821Yp8Vk4Pw"
    Silth::JWT.decode(foreign, "loco-secret")["pid"].should eq("11111111-2222-3333-4444-555555555555")
    expect_raises(Silth::JWT::Invalid) { Silth::JWT.decode(foreign, "other") }
    none = Base64.urlsafe_encode(%({"alg":"none"}), padding: false) + "." + foreign.split('.')[1] + "."
    expect_raises(Silth::JWT::Invalid) { Silth::JWT.decode(none, "loco-secret") }
  end

  it "issues and validates JWTs and TOTP codes" do
    token = Silth::JWT.encode({"sub" => "42"}, "k", expires_in: 1.minute)
    Silth::JWT.decode(token, "k")["sub"].as_s.should eq("42")
    expect_raises(Silth::JWT::Invalid) { Silth::JWT.decode(token, "wrong") }
    secret = Silth::Auth::TOTP.generate_secret
    Silth::Auth::TOTP.verify(secret, Silth::Auth::TOTP.code(secret)).should be_true
    # RFC 6238 test vector (SHA1, T=59)
    rfc = Silth::Auth::TOTP.base32_encode("12345678901234567890".to_slice)
    Silth::Auth::TOTP.code(rfc, Time.unix(59), digits: 8).should eq("94287082")
  end
end

describe Silth::Markdown do
  it "renders headings, code, tables and callouts" do
    doc = Silth::Markdown.parse(<<-MD)
      ---
      title: Guide
      ---
      # Title
      Some *em* and **strong** with `code` and [link](https://x.test).

      ```crystal
      def hi : String
        "hi"
      end
      ```

      | a | b |
      |---|--:|
      | 1 | 2 |

      > [!TIP]
      > Be kind.

      - one
      - two
      MD
    doc.title.should eq("Guide")
    doc.headings.first.id.should eq("title")
    doc.html.should contain("<em>em</em>")
    doc.html.should contain(%(<span class="tok-keyword">def</span>))
    doc.html.should contain("<table>")
    doc.html.should contain(%(class="callout callout-tip"))
    doc.html.should contain("<li>two</li>")
  end
end

describe Silth::I18n do
  it "translates with interpolation and plural rules" do
    Silth::I18n.t("greeting", locale: "fr", name: "Ada").should eq("Bonjour Ada")
    Silth::I18n.t("apples", locale: "fr", count: 0).should eq("0 pomme")
    Silth::I18n.t("apples", locale: "en", count: 0).should eq("No apples")
    Silth::I18n.t("apples", locale: "en", count: 3).should eq("3 apples")
    Silth::I18n.t("missing.key", locale: "en", default: "Fallback").should eq("Fallback")
    Silth::I18n.l(Time.utc(2026, 3, 1, 10, 0), "long", locale: "fr").should eq("1 mars 2026 à 10:00")
  end
end

describe Silth::Cron do
  it "matches expressions" do
    cron = Silth::Cron.new("*/15 9-17 * * mon-fri")
    cron.due?(Time.utc(2026, 11, 24, 9, 30)).should be_true
    cron.due?(Time.utc(2026, 11, 24, 9, 31)).should be_false
    cron.due?(Time.utc(2026, 11, 22, 9, 30)).should be_false # sunday
    Silth::Cron.new("0 3 * * *").next_after(Time.utc(2026, 11, 24, 4, 0)).should eq(Time.utc(2026, 11, 25, 3, 0))
  end
end

describe Silth::Router do
  it "matches static, params, constraints and globs" do
    router = Silth::Router.new
    handler = ->(ctx : Silth::Context) { nil }
    router.add(Silth::Route.new("GET", "/posts/new", handler, "posts.new"))
    router.add(Silth::Route.new("GET", "/posts/:id", handler, "posts.show"))
    router.add(Silth::Route.new("GET", "/n/:id<\\d+>", handler, "num"))
    router.add(Silth::Route.new("GET", "/assets/*path", handler, "assets"))
    router.match("GET", "/posts/new").not_nil!.route.name.should eq("posts.new")
    router.match("GET", "/posts/12").not_nil!.params["id"].should eq("12")
    router.match("GET", "/n/abc").should be_nil
    router.match("GET", "/assets/css/app.css").not_nil!.params["path"].should eq("css/app.css")
    router.match("HEAD", "/posts/1").should_not be_nil
    router.url_for("posts.show", id: 5, page: 2).should eq("/posts/5?page=2")
  end
end

describe Silth::Workflow do
  it "applies transitions with guards" do
    Silth::Workflow.define("note_flow") do |w|
      w.marking_property = "status"
      w.place("draft", "review", "published")
      w.transition("submit", "draft", "review")
      w.transition("publish", "review", "published", guard: "long_enough")
    end
    Silth::Workflow.guard("note_flow", "long_enough") { |subject, _| subject.as(Note).title.size > 3 }
    note = Note.create!(title: "Hey")
    wf = Silth::Workflow.get("note_flow")
    wf.enabled_transitions(note).should eq(["submit"])
    wf.apply(note, "submit")
    note.reload.status.should eq("review")
    wf.can?(note, "publish").should be_false
    note.title = "Long title"
    wf.apply(note, "publish")
    note.reload.status.should eq("published")
    wf.definition.to_mermaid.should contain("draft --> review : submit")
  end
end
