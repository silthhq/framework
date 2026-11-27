require "./spec_helper"

private def pg_connect(url : String) : Silth::DB::Postgres::Connection
  Silth::DB::Postgres::Connection.new(URI.parse(url))
end

private def with_params(url : String, params : String) : String
  url + (url.includes?('?') ? "&" : "?") + params
end

if (url = ENV["SILTH_TEST_DATABASE_URL"]?) && url.starts_with?("postgres")
  describe Silth::DB::Postgres::Connection do
    it "prepares a statement once and reuses it" do
      conn = pg_connect(url)
      before = conn.prepared_statements
      3.times { |i| conn.query("SELECT $1::int + 1 AS n", [i] of Silth::DB::Value).scalar.should eq(i + 1) }
      conn.prepared_statements.should eq(before + 1)
      conn.query("SELECT count(*) FROM pg_prepared_statements", [] of Silth::DB::Value).scalar.as(Int64).should be >= 1
    ensure
      conn.try &.close
    end

    it "prepares again when the table changed or the statements were discarded" do
      conn = pg_connect(url)
      conn.exec_script("CREATE TEMPORARY TABLE silth_stale (a int); INSERT INTO silth_stale VALUES (1)")
      conn.query("SELECT * FROM silth_stale", [] of Silth::DB::Value).columns.should eq(["a"])
      conn.exec_script("ALTER TABLE silth_stale ADD COLUMN b text DEFAULT 'x'")
      result = conn.query("SELECT * FROM silth_stale", [] of Silth::DB::Value)
      result.columns.should eq(["a", "b"])
      result.rows.first.should eq([1, "x"] of Silth::DB::Value)
      conn.exec_script("DISCARD ALL")
      conn.prepared_statements.should eq(0)
      conn.query("SELECT 1 AS one", [] of Silth::DB::Value).scalar.should eq(1)
    ensure
      conn.try &.close
    end

    it "keeps at most statement_cache_size statements" do
      conn = pg_connect(with_params(url, "statement_cache_size=2"))
      3.times { |i| conn.query("SELECT #{i} AS n", [] of Silth::DB::Value) }
      conn.prepared_statements.should eq(2)
      conn.query("SELECT count(*) FROM pg_prepared_statements", [] of Silth::DB::Value).scalar.should eq(2)
    ensure
      conn.try &.close
    end

    it "does not prepare with prepared_statements=false" do
      conn = pg_connect(with_params(url, "prepared_statements=false"))
      conn.query("SELECT 1 AS one", [] of Silth::DB::Value).scalar.should eq(1)
      conn.prepared_statements.should eq(0)
    ensure
      conn.try &.close
    end

    it "raises inside a transaction when a statement went stale" do
      conn = pg_connect(url)
      conn.exec_script("CREATE TEMPORARY TABLE silth_stale_tx (a int)")
      conn.query("SELECT * FROM silth_stale_tx", [] of Silth::DB::Value)
      conn.exec_script("ALTER TABLE silth_stale_tx ADD COLUMN b int")
      conn.exec_script("BEGIN")
      expect_raises(Silth::DB::QueryError, /cached plan/) { conn.query("SELECT * FROM silth_stale_tx", [] of Silth::DB::Value) }
      conn.exec_script("ROLLBACK")
      conn.query("SELECT * FROM silth_stale_tx", [] of Silth::DB::Value).columns.should eq(["a", "b"])
    ensure
      conn.try &.close
    end
  end
end
