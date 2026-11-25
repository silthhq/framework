require "./spec_helper"

# PostgreSQL only: SILTH_TEST_POSTGRES_URL, or SILTH_TEST_DATABASE_URL when it is
# postgres://. A separate connection keeps these specs out of the per-example
# transaction (the log backend writes from its own fiber).
module UnloggedSpec
  URL = ENV["SILTH_TEST_POSTGRES_URL"]? || ENV["SILTH_TEST_DATABASE_URL"]?.try { |u| u.starts_with?("postgres") ? u : nil }

  def self.db : Silth::DB::Database
    Silth::DB.connection("unlogged")
  end

  def self.unlogged?(table : String) : Bool
    db.scalar("SELECT relpersistence::text FROM pg_class WHERE relname = ?", [table]) == "u"
  end

  def self.context(cookie : String? = nil) : Silth::Context
    headers = HTTP::Headers.new
    headers["Cookie"] = cookie if cookie
    Silth::Context.new(HTTP::Server::Context.new(HTTP::Request.new("GET", "/", headers), HTTP::Server::Response.new(IO::Memory.new)))
  end

  def self.wait_until(timeout : Time::Span = 3.seconds, &) : Nil
    deadline = Time.utc + timeout
    until yield
      raise "timed out" if Time.utc > deadline
      sleep 20.milliseconds
    end
  end
end

describe Silth::CacheSessionStore do
  it "forgets the previous id when the session is regenerated" do
    store = Silth::CacheSessionStore.new("_spec_session", Silth.verifier("session"), Silth::CookieOptions.new, 1.hour)
    session = Silth::Session.new
    session["user_id"] = "42"
    ctx = UnloggedSpec.context
    store.save(ctx, session)
    cookie = ctx.response.cookies["_spec_session"].value
    session.invalidate
    store.save(UnloggedSpec.context, session)
    store.load(UnloggedSpec.context("_spec_session=#{cookie}")).not_nil!["user_id"]?.should be_nil
  end
end

if url = UnloggedSpec::URL
  Silth::DB.register("unlogged", url, 4)

  describe Silth::PostgresCache do
    it "caches in an UNLOGGED table with atomic add and increment" do
      cache = Silth::PostgresCache.new("pg", "unlogged", "silth_spec_cache")
      begin
        cache.set("a", "1")
        cache.get("a").should eq("1")
        cache.add("a", "2", nil).should be_false
        cache.add("b", "2", nil).should be_true

        cache.set("short", "x", 10.milliseconds)
        sleep 30.milliseconds
        cache.get("short").should be_nil
        cache.add("short", "y", nil).should be_true # an expired value does not block add

        cache.increment("hits", 5, 1.minute).should eq(5)
        done = Channel(Nil).new
        20.times { spawn { cache.increment("hits"); done.send(nil) } }
        20.times { done.receive }
        cache.get("hits").should eq("25")

        cache.fetch("computed", 1.minute) { "fresh" }.should eq("fresh")
        cache.delete("a").should be_true
        UnloggedSpec.unlogged?("silth_spec_cache").should be_true
      ensure
        UnloggedSpec.db.query("DROP TABLE IF EXISTS silth_spec_cache")
      end
    end
  end

  describe Silth::PostgresSessionStore do
    it "keeps the data server side and a signed id in the cookie" do
      store = Silth::PostgresSessionStore.new("_spec_session", Silth.verifier("session"), Silth::CookieOptions.new, 1.hour, "unlogged")
      session = Silth::Session.new
      session["user_id"] = "42"
      ctx = UnloggedSpec.context
      store.save(ctx, session)
      cookie = ctx.response.cookies["_spec_session"].value
      Silth.verifier("session").verify?(cookie).should eq(session.id) # the id only, no data

      store.load(UnloggedSpec.context("_spec_session=#{cookie}")).not_nil!["user_id"].should eq("42")
      store.load(UnloggedSpec.context("_spec_session=forged")).should be_nil
      UnloggedSpec.unlogged?("silth_sessions").should be_true

      old_id = session.id
      session.invalidate # logout: the old cookie must stop working
      store.save(UnloggedSpec.context, session)
      UnloggedSpec.db.scalar("SELECT COUNT(*) FROM silth_sessions WHERE id IN (?, ?)", [old_id, session.id]).should eq(0)
      store.load(UnloggedSpec.context("_spec_session=#{cookie}")).not_nil!["user_id"]?.should be_nil
    end
  end

  describe Silth::Logging::PostgresBackend do
    it "writes entries from a background fiber, never the database layer's own" do
      UnloggedSpec.db.query("DROP TABLE IF EXISTS silth_logs")
      backend = Silth::Logging::PostgresBackend.new("unlogged", interval: 50.milliseconds)
      backend.write(::Log::Entry.new("spec.orders", :warn, "stock is low", ::Log::Metadata.build({sku: "A1"}), nil))
      backend.write(::Log::Entry.new("silth.db", :debug, "SELECT 1", ::Log::Metadata.empty, nil))
      UnloggedSpec.wait_until { UnloggedSpec.db.table_exists?("silth_logs") && UnloggedSpec.db.scalar("SELECT COUNT(*) FROM silth_logs") == 1 }
      row = UnloggedSpec.db.query("SELECT level, source, message, data->>'sku' FROM silth_logs").rows.first
      row.should eq(["warn", "spec.orders", "stock is low", "A1"])
      UnloggedSpec.unlogged?("silth_logs").should be_true
      UnloggedSpec.db.query("DROP TABLE silth_logs")
    end
  end

  describe "UNLOGGED tables in the schema DSL" do
    it "creates them and dumps them as such" do
      schema = Silth::DB::Schema.new(UnloggedSpec.db)
      schema.create_table(:spec_events, unlogged: true) do |t|
        t.id
        t.string :name
      end
      UnloggedSpec.unlogged?("spec_events").should be_true
      Silth::DB::SchemaDumper.new(UnloggedSpec.db).dump.should contain(%(s.create_table "spec_events", unlogged: true do |t|))
    ensure
      UnloggedSpec.db.query("DROP TABLE IF EXISTS spec_events")
    end
  end
end
