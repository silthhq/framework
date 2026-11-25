module Silth
  # Versioned schema change.
  #
  # Write `change` when every step can be undone automatically (`create_table`,
  # `add_column`, `rename_column`, `add_index`, `add_foreign_key`…): rolling back
  # replays it backwards. Use `up`/`down` for anything else.
  #
  # ```
  # class CreatePosts < Silth::Migration
  #   version 2026_11_24_120000
  #
  #   def change
  #     enable_extension "vector"
  #     create_table :posts do |t|
  #       t.id
  #       t.string :title, null: false
  #       t.timestamps
  #     end
  #     add_index :posts, :title
  #     reversible do |dir|
  #       dir.up { execute "UPDATE posts SET title = upper(title)" }
  #       dir.down { execute "UPDATE posts SET title = lower(title)" }
  #     end
  #   end
  # end
  # ```
  abstract class Migration
    class Irreversible < Silth::Error; end

    # Runs a block in one direction only, inside `reversible`.
    class Direction
      def initialize(@reverting : Bool, @recorded : Array(-> Nil)?)
      end

      def up(&block : -> Nil) : Nil
        block.call unless @reverting
      end

      def down(&block : -> Nil) : Nil
        @recorded.try(&.<< block) if @reverting
      end
    end

    getter schema : DB::Schema
    # Inverse commands collected while `change` is replayed to roll back (nil otherwise).
    @inverse : Array(-> Nil)? = nil

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

    def up
      {% if @type.methods.any? { |m| m.name == "change" } %}
        change
      {% else %}
        raise Silth::Error.new("#{self.class.name} must define `change` or `up`")
      {% end %}
    end

    def down
      {% if @type.methods.any? { |m| m.name == "change" } %}
        revert { change }
      {% else %}
        raise Irreversible.new("#{self.class.name} cannot be rolled back (no `down` or `change` method)")
      {% end %}
    end

    # True while `change` is being replayed to roll back.
    def reverting? : Bool
      !@inverse.nil?
    end

    # Runs the block's schema commands backwards: each command is recorded, then
    # its inverse runs, last command first.
    def revert(&) : Nil
      outer = @inverse
      @inverse = recorded = [] of -> Nil
      begin
        yield
      ensure
        @inverse = outer
      end
      recorded.reverse_each(&.call)
    end

    # Direction-specific code inside `change` (data fixes, raw SQL).
    def reversible(& : Direction ->) : Nil
      yield Direction.new(reverting?, @inverse)
    end

    delegate table_exists?, to: @schema

    def execute(sql : String) : Nil
      irreversible!("execute (wrap it in `reversible`)") if reverting?
      @schema.execute(sql)
    end

    def create_table(name : String | Symbol, if_not_exists : Bool = false, unlogged : Bool = false, &block : DB::TableBuilder ->) : Nil
      return record_inverse { @schema.drop_table(name) } if reverting?
      @schema.create_table(name, if_not_exists, unlogged, &block)
    end

    # Reversible when the block describes the table to recreate.
    def drop_table(name : String | Symbol, if_exists : Bool = true, cascade : Bool = false, &block : DB::TableBuilder ->) : Nil
      return record_inverse { @schema.create_table(name, &block) } if reverting?
      @schema.drop_table(name, if_exists, cascade)
    end

    def drop_table(name : String | Symbol, if_exists : Bool = true, cascade : Bool = false) : Nil
      irreversible!("drop_table without a block describing the table") if reverting?
      @schema.drop_table(name, if_exists, cascade)
    end

    def rename_table(from : String | Symbol, to : String | Symbol) : Nil
      return record_inverse { @schema.rename_table(to, from) } if reverting?
      @schema.rename_table(from, to)
    end

    def add_column(table : String | Symbol, name : String | Symbol, type : Symbol, **opts) : Nil
      return record_inverse { @schema.remove_column(table, name) } if reverting?
      @schema.add_column(table, name, type, **opts)
    end

    # Reversible when the type (and options) of the removed column are given.
    def remove_column(table : String | Symbol, name : String | Symbol, type : Symbol? = nil, **opts) : Nil
      if reverting?
        builder = DB::TableBuilder.new(table.to_s, @schema.dialect)
        builder.column(name, type || irreversible!("remove_column without the column type"), **opts)
        return record_inverse { @schema.add_columns(builder) }
      end
      @schema.remove_column(table, name)
    end

    def rename_column(table : String | Symbol, from : String | Symbol, to : String | Symbol) : Nil
      return record_inverse { @schema.rename_column(table, to, from) } if reverting?
      @schema.rename_column(table, from, to)
    end

    def change_column(table : String | Symbol, name : String | Symbol, type : Symbol, null : Bool = true, limit : Int32? = nil) : Nil
      irreversible!("change_column (use up/down)") if reverting?
      @schema.change_column(table, name, type, null, limit)
    end

    def add_index(table : String | Symbol, columns : String | Symbol | Array, unique : Bool = false, name : String? = nil,
                  using : String? = nil, where : String? = nil, opclass : String? = nil) : Nil
      return record_inverse { @schema.remove_index(table, name || DB::Schema.index_name(table, columns)) } if reverting?
      @schema.add_index(table, columns, unique, name, using, where, opclass)
    end

    def remove_index(table : String | Symbol, name : String) : Nil
      irreversible!("remove_index by name (pass the columns instead)") if reverting?
      @schema.remove_index(table, name)
    end

    # Reversible: `remove_index :posts, columns: :title, unique: true`.
    def remove_index(table : String | Symbol, *, columns : String | Symbol | Array, unique : Bool = false) : Nil
      return record_inverse { @schema.add_index(table, columns, unique) } if reverting?
      @schema.remove_index(table, columns: columns)
    end

    def add_foreign_key(table : String | Symbol, column : String | Symbol, to_table : String | Symbol, on_delete : Symbol? = nil,
                        on_update : Symbol? = nil, name : String? = nil) : Nil
      return record_inverse { @schema.remove_foreign_key(table, column, name) } if reverting?
      @schema.add_foreign_key(table, column, to_table, on_delete, on_update, name)
    end

    # Reversible when the referenced table is given.
    def remove_foreign_key(table : String | Symbol, column : String | Symbol, to_table : String | Symbol? = nil,
                           on_delete : Symbol? = nil, name : String? = nil) : Nil
      if reverting?
        target = to_table || irreversible!("remove_foreign_key without the referenced table")
        return record_inverse { @schema.add_foreign_key(table, column, target, on_delete, name: name) }
      end
      @schema.remove_foreign_key(table, column, name)
    end

    def enable_extension(name : String) : Nil
      return record_inverse { @schema.disable_extension(name) } if reverting?
      @schema.enable_extension(name)
    end

    def disable_extension(name : String) : Nil
      return record_inverse { @schema.enable_extension(name) } if reverting?
      @schema.disable_extension(name)
    end

    private def record_inverse(&block : -> Nil) : Nil
      @inverse.not_nil! << block
    end

    private def irreversible!(what : String) : NoReturn
      raise Irreversible.new("#{self.class.name} cannot be rolled back: #{what}")
    end

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
    Log   = ::Log.for("silth.migrate")
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

    # Records *versions* as applied without running them (after `db:schema:load`).
    def mark_applied(versions : Array(Int64)) : Nil
      done = applied
      versions.reject { |v| done.has_key?(v) }.each do |version|
        name = migrations_for_db.find { |m| m.version == version }.try(&.name) || "schema"
        @db.table(TABLE).insert({"version" => version.as(DB::Value), "name" => name.as(DB::Value), "batch" => 1.as(DB::Value),
                                 "migrated_at" => Time.utc.as(DB::Value)}, returning: nil)
      end
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
