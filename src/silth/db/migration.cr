module Silth
  # Versioned schema change.
  #
  # ```
  # class CreatePosts < Silth::Migration
  #   version 2026_11_24_120000
  #
  #   def up
  #     enable_extension "vector"
  #     create_table :posts do |t|
  #       t.id
  #       t.string :title, null: false
  #       t.timestamps
  #     end
  #   end
  #
  #   def down
  #     drop_table :posts
  #   end
  # end
  # ```
  abstract class Migration
    class Irreversible < Silth::Error; end

    getter schema : DB::Schema

    def initialize(@schema : DB::Schema)
    end

    macro version(number)
      def self.version : Int64
        {{number}}.to_i64
      end
    end

    # Overridden by the `version` macro; 0 means "missing" and is rejected by the migrator.
    def self.version : Int64
      0_i64
    end

    def self.connection_name : String?
      nil
    end

    macro connection(name)
      def self.connection_name : String?
        {{name.id.stringify}}
      end
    end

    abstract def up

    def down
      raise Irreversible.new("#{self.class.name} cannot be rolled back (no `down` method)")
    end

    delegate execute, create_table, drop_table, rename_table, add_column, remove_column, rename_column,
      change_column, add_index, remove_index, add_foreign_key, enable_extension, table_exists?, to: @schema

    # Every concrete migration compiled into the program, sorted by version.
    def self.all : Array(Migration.class)
      {% begin %}
        list = [{% for t in @type.all_subclasses.reject(&.abstract?) %}{{t}}, {% end %}] of Migration.class
        list.sort { |a, b| a.version.as(Int64) <=> b.version.as(Int64) }
      {% end %}
    end
  end

  # Runs migrations and records them in `silth_migrations`.
  class Migrator
    Log = ::Log.for("silth.migrate")
    TABLE = "silth_migrations"

    record Status, version : Int64, name : String, applied : Bool, batch : Int32?

    getter db : DB::Database

    def initialize(@db : DB::Database = DB.connection, @migrations : Array(Migration.class) = Migration.all)
    end

    def ensure_table : Nil
      DB::Schema.new(@db).create_table(TABLE, if_not_exists: true) do |t|
        t.bigint :version, null: false
        t.string :name, null: false
        t.integer :batch, null: false
        t.timestamp :migrated_at
      end
    end

    def applied : Hash(Int64, {String, Int32})
      ensure_table
      result = {} of Int64 => {String, Int32}
      @db.table(TABLE).rows.each do |row|
        result[DB.as_i64(row["version"])] = {row["name"].to_s, DB.as_i64(row["batch"]).to_i32}
      end
      result
    end

    def migrations_for_db : Array(Migration.class)
      @migrations.select { |m| (m.connection_name || DB.default) == @db.name }
    end

    def pending : Array(Migration.class)
      done = applied
      migrations_for_db.reject { |m| done.has_key?(m.version) }
    end

    def status : Array(Status)
      done = applied
      list = migrations_for_db.map { |m| Status.new(m.version, m.name, done.has_key?(m.version), done[m.version]?.try(&.[1])) }
      done.each do |version, (name, batch)|
        list << Status.new(version, "#{name} (missing file)", true, batch) unless migrations_for_db.any? { |m| m.version == version }
      end
      list.sort_by(&.version)
    end

    # Runs pending migrations; returns the names that ran.
    def migrate(steps : Int32? = nil) : Array(String)
      todo = pending
      if missing = todo.find { |m| m.version == 0 }
        raise Silth::Error.new("#{missing.name} has no version; add `version YYYY_MM_DD_HHMMSS`")
      end
      todo = todo.first(steps) if steps
      return [] of String if todo.empty?
      batch = (applied.values.map(&.[1]).max? || 0) + 1
      ran = [] of String
      todo.each do |klass|
        started = Time.instant
        run_one(klass) do |schema|
          klass.new(schema).up
          @db.table(TABLE).insert({"version" => klass.version.as(DB::Value), "name" => klass.name.as(DB::Value), "batch" => batch.as(DB::Value), "migrated_at" => Time.utc.as(DB::Value)}, returning: nil)
        end
        Log.info { "Migrated #{klass.version} #{klass.name} (#{(Time.instant - started).total_milliseconds.round(1)}ms)" }
        ran << klass.name
      end
      ran
    end

    # Rolls back the last batch (or the last `steps` migrations).
    def rollback(steps : Int32? = nil) : Array(String)
      done = applied
      return [] of String if done.empty?
      versions = if steps
                   done.keys.sort.reverse.first(steps)
                 else
                   last_batch = done.values.map(&.[1]).max
                   done.select { |_, v| v[1] == last_batch }.keys.sort.reverse
                 end
      rolled = [] of String
      versions.each do |version|
        klass = migrations_for_db.find { |m| m.version == version }
        raise Silth::Error.new("Migration #{version} is applied but its class is missing") unless klass
        run_one(klass) do |schema|
          klass.new(schema).down
          @db.table(TABLE).where(version: version).delete
        end
        Log.info { "Rolled back #{version} #{klass.name}" }
        rolled << klass.name
      end
      rolled
    end

    def reset : Array(String)
      rolled = [] of String
      until applied.empty?
        rolled.concat(rollback)
      end
      rolled
    end

    # Drops every table then migrates from scratch.
    def fresh : Array(String)
      drop_all_tables
      migrate
    end

    def drop_all_tables : Nil
      d = @db.dialect
      tables = @db.tables
      case d.name
      when "mysql"
        @db.exec_script("SET FOREIGN_KEY_CHECKS = 0")
        tables.each { |t| @db.query("DROP TABLE IF EXISTS #{d.quote(t)}") }
        @db.exec_script("SET FOREIGN_KEY_CHECKS = 1")
      when "sqlite"
        @db.exec_script("PRAGMA foreign_keys = OFF")
        tables.each { |t| @db.query("DROP TABLE IF EXISTS #{d.quote(t)}") }
        @db.exec_script("PRAGMA foreign_keys = ON")
      else
        tables.each { |t| @db.query("DROP TABLE IF EXISTS #{d.quote(t)} CASCADE") }
      end
    end

    private def run_one(klass : Migration.class, & : DB::Schema ->) : Nil
      schema = DB::Schema.new(@db)
      if @db.dialect.supports_transactional_ddl?
        @db.transaction { yield schema }
      else
        yield schema
      end
    end
  end

  # Database seeders: `silth db:seed` runs `DatabaseSeeder` (or every seeder).
  abstract class Seeder
    abstract def run

    def call(klass : Seeder.class) : Nil
      ::Log.for("silth.seed").info { "Seeding #{klass.name}" }
      klass.new.run
    end

    def fake : Fake.class
      Fake
    end

    def self.all : Array(Seeder.class)
      {% begin %}
        [{% for t in @type.all_subclasses.reject(&.abstract?) %}{{t}}, {% end %}] of Seeder.class
      {% end %}
    end

    def self.run_default : Nil
      list = all
      if main = list.find { |k| k.name.ends_with?("DatabaseSeeder") }
        main.new.run
      else
        list.each &.new.run
      end
    end
  end

  # Model factories for tests and seeds.
  #
  # ```
  # class PostFactory < Silth::Factory(Post)
  #   def definition : Post
  #     Post.new(title: fake.sentence, body: fake.paragraph, user_id: UserFactory.create.id)
  #   end
  # end
  #
  # PostFactory.create(title: "Pinned")
  # PostFactory.create_list(10)
  # ```
  # :nodoc:
  module FactorySequences
    class_getter counters = Hash(String, Int32).new(0)
  end

  abstract class Factory(T)

    abstract def definition : T

    def fake : Fake.class
      Fake
    end

    def sequence(name : String = self.class.name) : Int32
      FactorySequences.counters[name] += 1
    end

    def self.build(**attrs) : T
      record = new.definition
      record.assign(**attrs)
      record
    end

    def self.create(**attrs) : T
      build(**attrs).save!
    end

    def self.build_list(count : Int32, **attrs) : Array(T)
      Array(T).new(count) { build(**attrs) }
    end

    def self.create_list(count : Int32, **attrs) : Array(T)
      Array(T).new(count) { create(**attrs) }
    end
  end
end
