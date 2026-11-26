require "./spec_helper"

# Two SQLite files with different rows stand for a primary and its replica: the
# rows a query returns tell where it ran.
module ReplicaSpec
  DIR = "spec/tmp/replicas"

  def self.database(replicas = ["replica"]) : Silth::DB::Database
    FileUtils.rm_rf(DIR)
    Dir.mkdir_p(DIR)
    (["primary"] + replicas).each do |name|
      db = Silth::DB::Database.new("setup_#{name}", "sqlite3://#{DIR}/#{name}.db", 1)
      db.exec_script("CREATE TABLE items (name TEXT); INSERT INTO items VALUES ('#{name}')")
      db.close
    end
    Silth::DB::Database.new("replicated", "sqlite3://#{DIR}/primary.db", 2, replicas: replicas.map { |r| "sqlite3://#{DIR}/#{r}.db" })
  end

  def self.source(db : Silth::DB::Database) : String
    db.scalar("SELECT name FROM items ORDER BY rowid LIMIT 1").to_s
  end
end

describe Silth::DB::Replica do
  it "reads from the replica, writes and transactions on the primary" do
    db = ReplicaSpec.database
    Silth::DB.reset_stickiness
    ReplicaSpec.source(db).should eq("replica")
    db.transaction { ReplicaSpec.source(db) }.should eq("primary")
    Silth::DB.on_primary { ReplicaSpec.source(db) }.should eq("primary")
  ensure
    db.try &.close
  end

  it "keeps reading from the primary after a write in the same unit of work" do
    db = ReplicaSpec.database
    Silth::DB.reset_stickiness
    db.exec("INSERT INTO items VALUES ('written')")
    ReplicaSpec.source(db).should eq("primary")
    db.scalar("SELECT COUNT(*) FROM items").should eq(2) # the primary sees its own write
    Silth::DB.reset_stickiness                           # next request or job
    ReplicaSpec.source(db).should eq("replica")
  ensure
    db.try &.close
  end

  it "takes the replicas in turn and rests one it cannot reach" do
    db = ReplicaSpec.database(["one", "two"])
    db.add_replica("sqlite3://#{ReplicaSpec::DIR}") # a directory: cannot be opened
    Silth::DB.reset_stickiness
    # The third replica cannot be opened: that read falls back to the primary,
    # then the replica rests and its turn goes to the next one.
    Array.new(6) { ReplicaSpec.source(db) }.should eq(["one", "two", "primary", "one", "two", "one"])
    db.replicas.last.available?.should be_false
  ensure
    db.try &.close
  end

  it "keeps a client on the primary for sticky_for after a write (cookie)" do
    db = ReplicaSpec.database
    Silth::DB.databases["replicated"] = db
    begin
      first = Silth::Context.new(HTTP::Server::Context.new(HTTP::Request.new("POST", "/items"), HTTP::Server::Response.new(IO::Memory.new)))
      Silth::DB.begin_request(first)
      db.exec("INSERT INTO items VALUES ('written')")
      first.run_before_send
      cookie = first.response.cookies[Silth::DB::STICKY_COOKIE]
      cookie.value.should eq("replicated")

      request = HTTP::Request.new("GET", "/items/1", HTTP::Headers{"Cookie" => "#{Silth::DB::STICKY_COOKIE}=replicated"})
      second = Silth::Context.new(HTTP::Server::Context.new(request, HTTP::Server::Response.new(IO::Memory.new)))
      Silth::DB.begin_request(second)
      ReplicaSpec.source(db).should eq("primary")

      third = Silth::Context.new(HTTP::Server::Context.new(HTTP::Request.new("GET", "/items/1"), HTTP::Server::Response.new(IO::Memory.new)))
      Silth::DB.begin_request(third)
      ReplicaSpec.source(db).should eq("replica")
    ensure
      Silth::DB.databases.delete("replicated")
      db.close
      Silth::DB.reset_stickiness
    end
  end

  it "tells reads from statements a replica must not run" do
    {"SELECT 1"                                                    => true,
     "  (SELECT 1) UNION (SELECT 2)"                               => true,
     "WITH t AS (SELECT 1) SELECT * FROM t"                        => true,
     "SHOW TABLES"                                                 => true,
     "SELECT * FROM jobs FOR UPDATE SKIP LOCKED"                   => false,
     "SELECT * FROM t LOCK IN SHARE MODE"                          => false,
     "SELECT * FROM t FOR NO KEY UPDATE"                           => false,
     "SELECT nextval('posts_id_seq')"                              => false,
     "SELECT pg_advisory_lock(1)"                                  => false,
     "WITH gone AS (DELETE FROM t RETURNING *) SELECT * FROM gone" => false,
     "INSERT INTO t VALUES (1)"                                    => false,
     "UPDATE t SET a = 1"                                          => false,
    }.each do |sql, read|
      Silth::DB.read_statement?(sql).should eq(read), "#{sql.inspect} should#{read ? "" : " not"} be a read"
    end
  end

  it "refuses a replica of another kind of database" do
    expect_raises(Silth::DB::ConnectionError, /not a sqlite database/) do
      Silth::DB::Database.new("mixed", "sqlite3::memory:", 1, replicas: ["postgres://localhost/app"])
    end
  end
end
