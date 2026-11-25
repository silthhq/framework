require "./spec_helper"

# Relaying between nodes needs SILTH_TEST_REDIS_URL and/or a PostgreSQL URL
# (SILTH_TEST_POSTGRES_URL, or SILTH_TEST_DATABASE_URL when it is postgres://).
module PubSubSpec
  def self.postgres_url : String?
    ENV["SILTH_TEST_POSTGRES_URL"]? || ENV["SILTH_TEST_DATABASE_URL"]?.try { |u| u.starts_with?("postgres") ? u : nil }
  end

  def self.wait_until(timeout : Time::Span = 5.seconds, &) : Nil
    deadline = Time.utc + timeout
    until yield
      raise "timed out" if Time.utc > deadline
      sleep 20.milliseconds
    end
  end

  def self.receive(channel : ::Channel(String), timeout : Time::Span = 5.seconds) : String
    select
    when message = channel.receive then message
    when timeout(timeout) then raise "no message relayed"
    end
  end

  # Two adapters on the same channel stand for two server nodes.
  def self.nodes(& : -> Silth::PubSub::Adapter) : {Silth::PubSub::Adapter, Silth::PubSub::Adapter, ::Channel(String)}
    sender, listener = yield, yield
    received = ::Channel(String).new(16)
    listener.start { |payload| received.send(payload) }
    wait_until { listener.ready? }
    {sender, listener, received}
  end
end

describe Silth::PubSub do
  it "delivers to local subscribers, wildcards included" do
    got = [] of String
    id = Silth::PubSub.subscribe("orders:1") { |event, message| got << "#{event} #{message}" }
    wild = Silth::PubSub.subscribe("orders:*") { |event, _| got << "* #{event}" }
    Silth::PubSub.publish("orders:1", "paid", "{}")
    got.should eq(["paid {}", "* paid"])
    Silth::PubSub.unsubscribe("orders:1", id)
    Silth::PubSub.unsubscribe("orders:*", wild)
  end

  it "delivers messages relayed by other nodes, not its own" do
    got = [] of String
    id = Silth::PubSub.subscribe("relay") { |event, _| got << event }
    Silth::PubSub.receive({node: "other", topic: "relay", event: "from-other", message: "{}"}.to_json)
    Silth::PubSub.receive({node: Silth::PubSub.node, topic: "relay", event: "echo", message: "{}"}.to_json)
    got.should eq(["from-other"])
    Silth::PubSub.unsubscribe("relay", id)
  end

  it "picks the adapter from config/realtime.yml" do
    config = Silth::Config.new(YAML.parse(%(realtime:\n  pubsub: carrier-pigeon)))
    expect_raises(Silth::Error, /Unknown realtime.pubsub adapter 'carrier-pigeon'/) { Silth::PubSub.boot(config) }
  end

  if redis_url = ENV["SILTH_TEST_REDIS_URL"]?
    it "relays between nodes through Redis and reconnects" do
      channel = "silth:spec:#{Random::Secure.hex(4)}"
      sender, listener, received = PubSubSpec.nodes { Silth::PubSub::RedisAdapter.new(redis_url, channel) }
      sender.publish("hello")
      PubSubSpec.receive(received).should eq("hello")

      Silth::Redis.new(redis_url).command("CLIENT", "KILL", "TYPE", "pubsub")
      PubSubSpec.wait_until { !listener.ready? }
      PubSubSpec.wait_until { listener.ready? }
      sender.publish("again")
      PubSubSpec.receive(received).should eq("again")
      sender.stop
      listener.stop
    end
  end

  if pg_url = PubSubSpec.postgres_url
    it "relays between nodes through PostgreSQL LISTEN/NOTIFY and reconnects" do
      db = Silth::DB::Database.new("pubsub_spec", pg_url, 2)
      channel = "silth_spec_#{Random::Secure.hex(4)}"
      sender, listener, received = PubSubSpec.nodes { Silth::PubSub::PostgresAdapter.new(db, channel) }
      sender.publish("hello")
      PubSubSpec.receive(received).should eq("hello")
      big = "x" * 20_000 # over the 8000 byte NOTIFY limit
      sender.publish(big)
      PubSubSpec.receive(received).should eq(big)

      db.query("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'silth-pubsub'")
      PubSubSpec.wait_until { !listener.ready? }
      PubSubSpec.wait_until { listener.ready? }
      sender.publish("again")
      PubSubSpec.receive(received).should eq("again")
      sender.stop
      listener.stop
      db.query("DROP TABLE IF EXISTS #{Silth::PubSub::PostgresAdapter::OVERFLOW_TABLE}")
      db.close
    end
  end
end
