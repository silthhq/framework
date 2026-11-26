require "./spec_helper"

describe Silth::Commands::DbConsole do
  it "builds psql from the URL, the password in the environment" do
    client = Silth::Commands::DbConsole.client("postgres", URI.parse("postgres://app:s%40cret@db.internal:6432/blog?sslmode=require"))
    client.program.should eq("psql")
    client.args.should be_empty
    client.env.should eq({"PGHOST" => "db.internal", "PGPORT" => "6432", "PGDATABASE" => "blog", "PGUSER" => "app",
                          "PGPASSWORD" => "s@cret", "PGSSLMODE" => "require", "PGAPPNAME" => "silth db:console"})
  end

  it "builds the MySQL/MariaDB client without the password on the command line" do
    client = Silth::Commands::DbConsole.client("mysql", URI.parse("mysql://root:pw@127.0.0.1:53306/shop?ssl=true"))
    client.program.should match(/\A(mariadb|mysql)\z/)
    client.args.first(3).should eq(["--host=127.0.0.1", "--port=53306", "--user=root"])
    client.args.last.should eq("shop")
    client.args.join(" ").should_not contain("pw")
    client.args.should contain(client.program == "mariadb" ? "--ssl" : "--ssl-mode=REQUIRED")
    client.env.should eq({"MYSQL_PWD" => "pw"})
  end

  it "opens the SQLite file" do
    Silth::Commands::DbConsole.client("sqlite", Silth::DB.parse_url("sqlite3://./db/development.sqlite3")).args.should eq(["./db/development.sqlite3"])
  end

  it "prints the command without the password" do
    output = IO::Memory.new
    Silth::CLI.run(["db:console", "--print"], output)
    output.to_s.should match(/sqlite3|psql|mysql|mariadb/)
    output.to_s.should_not contain("silth:silth")
  end
end
