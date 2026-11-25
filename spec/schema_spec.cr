require "./spec_helper"
require "./fixtures/schema/*"

# Migrations bound to a connection that is never registered: the migrator ignores
# them, the specs run them by hand.
class ReversibleSpecMigration < Silth::Migration
  version 2026_11_25_000001
  connection spec_only

  def change
    create_table :rev_posts do |t|
      t.id
      t.string :title, null: false
    end
    add_column :rev_posts, :body, :text
    rename_column :rev_posts, :title, :headline
    add_index :rev_posts, :headline
    reversible do |dir|
      dir.up { schema.execute "INSERT INTO rev_posts (headline) VALUES ('created on the way up')" }
      dir.down { schema.execute "DELETE FROM rev_posts" }
    end
  end
end

class IrreversibleSpecMigration < Silth::Migration
  version 2026_11_25_000002
  connection spec_only

  def change
    add_column :rev_posts, :extra, :integer
    remove_column :rev_posts, :extra
  end
end

class DropWithoutBlockSpecMigration < Silth::Migration
  version 2026_11_25_000003
  connection spec_only

  def change
    drop_table :rev_posts
  end
end

module SchemaSpec
  def self.columns(table : String) : Array(String)
    Silth::DB::Schema.new.db.query("SELECT * FROM #{Silth::DB.connection.dialect.quote(table)} WHERE 1 = 0").columns
  end

  def self.dump : String
    Silth::DB::SchemaDumper.new(Silth::DB.connection).dump
  end

  def self.version : Int64
    Silth::Migrator.new.applied.keys.max
  end

  # A dump written by the dumper itself (spec/fixtures/schema), compiled in as code.
  # MariaDB reports a few things differently from MySQL 8, the fixture's source.
  def self.fixture(dialect : String) : {Silth::DB::SchemaDefinition, String}?
    return nil if dialect == "mysql" && Silth::DB.scalar("SELECT VERSION()").to_s.includes?("MariaDB")
    definition = Silth::DB::SchemaDefinition.for("fixture_#{dialect}") || return nil
    text = File.read("spec/fixtures/schema/#{dialect}.cr").sub(%(, connection: "fixture_#{dialect}"), "")
    {definition, text}
  end
end

describe Silth::Migration do
  it "rolls back a `change` migration by replaying it backwards" do
    migration = ReversibleSpecMigration.new(Silth::DB::Schema.new)
    migration.up
    SchemaSpec.columns("rev_posts").should eq(["id", "headline", "body"])
    Silth::DB.scalar("SELECT COUNT(*) FROM rev_posts").should eq(1)
    migration.down
    Silth::DB.connection.table_exists?("rev_posts").should be_false
  end

  it "refuses to roll back what it cannot reverse" do
    schema = Silth::DB::Schema.new
    expect_raises(Silth::Migration::Irreversible, /remove_column without the column type/) do
      IrreversibleSpecMigration.new(schema).down
    end
    expect_raises(Silth::Migration::Irreversible, /drop_table without a block/) do
      DropWithoutBlockSpecMigration.new(schema).down
    end
  end
end

describe "silth g migration" do
  it "writes `change` when the migration is reversible, `up`/`down` otherwise" do
    dir = File.tempname("silth-gen", nil)
    Dir.mkdir_p(dir)
    begin
      Dir.cd(dir) do
        Silth::Generators.generate("migration", "add_sku_to_products", ["sku:string"], output: IO::Memory.new)
        Silth::Generators.generate("migration", "backfill_prices", [] of String, output: IO::Memory.new)
        files = Dir.glob("db/migrations/*.cr")
        File.read(files.find(&.includes?("add_sku")).not_nil!).should contain("  def change\n    add_column :products, :sku, :string")
        File.read(files.find(&.includes?("backfill")).not_nil!).should contain("  def down\n    # reverse the change\n  end")
        files.map { |f| File.basename(f)[0, 14] }.uniq.size.should eq(2) # same second, distinct versions
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end

describe Silth::DB::SchemaDumper do
  it "writes tables, columns, defaults and indexes as the schema DSL" do
    dump = SchemaSpec.dump
    dump.should contain(%(Silth::DB::SchemaDefinition.define(version: #{SchemaSpec.version}) do |s|))
    dump.should contain(%(  s.create_table "notes" do |t|\n    t.id\n))
    dump.should contain(%(t.string "title", null: false, limit: 255))
    dump.should contain(%(t.integer "views", default: 0))
    dump.should contain(%(t.boolean "pinned", default: false))
    dump.should contain(%(t.string "status", default: "draft", limit: 255))
    dump.should contain(%(t.index ["author_id"], name: "index_notes_on_author_id"))
    dump.should_not contain(Silth::Migrator::TABLE)
    case Silth::DB.connection.dialect.name
    when "sqlite" then dump.should contain(%(t.foreign_key "author_id", "authors", on_delete: :nullify))
    else               dump.should contain(%(s.add_foreign_key "notes", "author_id", "authors", on_delete: :nullify))
    end
  end

  it "reloads to the same schema" do
    before = SchemaSpec.dump
    migrations = Silth::Migrator.new.migrations_for_db
    Silth::DB::SchemaDefinition.new(SchemaSpec.version, nil) { |s| migrations.each(&.new(s).up) }.load(Silth::DB.connection)
    SchemaSpec.dump.should eq(before)
    Silth::Migrator.new.pending.should be_empty
  end

  it "loads the code it generates and dumps it back unchanged" do
    dialect = Silth::DB.connection.dialect.name
    definition, text = SchemaSpec.fixture(dialect) || next
    begin
      definition.load(Silth::DB.connection)
      SchemaSpec.dump.should eq(text)
    ensure # MySQL commits DDL: put the spec schema back
      Silth::Migrator.new.fresh if dialect == "mysql"
    end
  end
end
