module Silth::DB
  # Reads the structure of a database and writes it back as the schema DSL
  # (`db/schema.cr`), which `silth db:schema:load` replays at once instead of every
  # migration.
  #
  # ```
  # File.write("db/schema.cr", Silth::DB::SchemaDumper.new(Silth::DB.connection).dump)
  # ```
  #
  # Tables, columns, defaults, primary keys, indexes, foreign keys and PostgreSQL
  # extensions are dumped. Indexes the DSL cannot express (expressions) are kept as
  # raw SQL. Check constraints, views, triggers and functions are not dumped.
  class SchemaDumper
    record ColumnInfo, name : String, type : String, null : Bool = true, default : String? = nil,
      limit : Int32? = nil, precision : Int32? = nil, scale : Int32? = nil, dimensions : Int32? = nil,
      generated : String? = nil, unique : Bool = false, comment : String? = nil

    record IndexInfo, name : String, columns : Array(String), unique : Bool = false, using : String? = nil,
      where : String? = nil, opclass : String? = nil, fulltext : Bool = false

    record ForeignKeyInfo, name : String?, column : String, table : String, ref_column : String,
      on_delete : Symbol?, on_update : Symbol?

    # One table as read from the database. `id_type` is set when the primary key is
    # what `t.id` creates (auto-increment integer or UUID).
    record TableInfo, name : String, columns : Array(ColumnInfo), primary_key : Array(String),
      id_type : Symbol?, indexes : Array(IndexInfo), raw_indexes : Array(String), foreign_keys : Array(ForeignKeyInfo)

    # Types written with a `t.<type>` helper (the others use `t.column`).
    HELPER_TYPES = %w(string text integer bigint smallint float real boolean date time binary uuid inet citext json
      string_array integer_array float_array)
    # Every type name the dialects translate. A database type spelled like one of them
    # (PostgreSQL's plain `json`) is dumped in upper case so it is kept as is.
    DSL_TYPES = HELPER_TYPES + %w(decimal timestamp vector tsvector int)

    # A database type that is not a DSL type, as written in the dump.
    def self.raw_type(sql : String) : String
      DSL_TYPES.includes?(sql) ? sql.upcase : sql
    end

    # Framework tables that are not part of the application schema.
    IGNORED_TABLES = [Migrator::TABLE, "silth_pubsub_messages"]

    getter db : Database

    def initialize(@db : Database = DB.connection)
    end

    # The schema as Crystal source.
    def dump : String
      introspector = SchemaIntrospector.for(@db)
      tables = (@db.tables - IGNORED_TABLES).sort.map { |name| introspector.table(name) }
      String.build do |io|
        io << "# Database schema, written by `silth db:schema:dump` (and after migrations in development).\n"
        io << "# Do not edit it: change the schema with migrations. `silth db:schema:load` recreates the\n"
        io << "# database from this file, much faster than running every migration.\n"
        io << "Silth::DB::SchemaDefinition.define(version: " << version
        io << ", connection: " << @db.name.inspect unless @db.name == DB.default
        io << ") do |s|\n"
        introspector.extensions.each { |ext| io << "  s.enable_extension " << ext.inspect << '\n' }
        tables.each_with_index do |table, i|
          io << '\n' if i > 0 || !introspector.extensions.empty?
          render_table(io, table, inline_foreign_keys: !introspector.add_foreign_keys_later?)
        end
        render_trailing(io, tables, introspector.add_foreign_keys_later?)
        io << "end\n"
      end
    end

    # Highest applied migration version (0 when none ran).
    def version : Int64
      return 0_i64 unless @db.table_exists?(Migrator::TABLE)
      DB.as_i64(@db.scalar("SELECT MAX(version) FROM #{@db.dialect.quote(Migrator::TABLE)}"))
    end

    private def render_table(io : IO, table : TableInfo, inline_foreign_keys : Bool) : Nil
      io << "  s.create_table " << table.name.inspect << " do |t|\n"
      table.columns.each do |col|
        if table.id_type && table.primary_key == [col.name]
          io << "    " << render_id(col, table.id_type.not_nil!) << '\n'
        else
          io << "    " << render_column(col) << '\n'
        end
      end
      if !table.id_type && !table.primary_key.empty?
        io << "    t.primary_key " << table.primary_key.inspect << '\n'
      end
      table.indexes.each { |idx| io << "    " << render_index(idx) << '\n' }
      table.foreign_keys.each { |fk| io << "    " << render_inline_foreign_key(fk) << '\n' } if inline_foreign_keys
      io << "  end\n"
    end

    private def render_trailing(io : IO, tables : Array(TableInfo), foreign_keys : Bool) : Nil
      lines = [] of String
      if foreign_keys
        tables.each { |t| t.foreign_keys.each { |fk| lines << render_foreign_key(t.name, fk) } }
      end
      tables.each { |t| t.raw_indexes.each { |sql| lines << "s.execute #{sql.inspect}" } }
      return if lines.empty?
      io << '\n'
      lines.each { |line| io << "  " << line << '\n' }
    end

    private def render_id(col : ColumnInfo, type : Symbol) : String
      args = [] of String
      args << ":#{type}" unless type == :bigint
      args << "name: #{col.name.inspect}" unless col.name == "id"
      args.empty? ? "t.id" : "t.id #{args.join(", ")}"
    end

    def render_column(col : ColumnInfo) : String
      head = case col.type
             when "decimal"
               col.precision ? "t.decimal #{col.name.inspect}, precision: #{col.precision}, scale: #{col.scale || 0}" : "t.column #{col.name.inspect}, :decimal"
             when "vector"    then "t.vector #{col.name.inspect}, #{col.dimensions || 1536}"
             when "timestamp" then "t.timestamp #{col.name.inspect}"
             else
               if HELPER_TYPES.includes?(col.type) && !col.generated
                 "t.#{col.type} #{col.name.inspect}"
               else
                 "t.column #{col.name.inspect}, #{symbol_literal(col.type)}"
               end
             end
      opts = [] of String
      opts << "null: false" unless col.null
      opts << "default: #{col.default}" if col.default && col.type != "vector"
      opts << "limit: #{col.limit}" if col.limit && col.type == "string"
      opts << "unique: true" if col.unique
      opts << "generated: #{col.generated.inspect}" if col.generated
      opts << "comment: #{col.comment.inspect}" if col.comment && (HELPER_TYPES.includes?(col.type) || head.starts_with?("t.column"))
      opts.empty? ? head : "#{head}, #{opts.join(", ")}"
    end

    private def render_index(idx : IndexInfo) : String
      if idx.fulltext
        return "t.fulltext #{idx.columns.inspect}, name: #{idx.name.inspect}"
      end
      opts = ["name: #{idx.name.inspect}"]
      opts.unshift("unique: true") if idx.unique
      opts << "using: #{idx.using.inspect}" if idx.using
      opts << "where: #{idx.where.inspect}" if idx.where
      opts << "opclass: #{idx.opclass.inspect}" if idx.opclass
      "t.index #{idx.columns.inspect}, #{opts.join(", ")}"
    end

    private def render_inline_foreign_key(fk : ForeignKeyInfo) : String
      "t.foreign_key #{fk.column.inspect}, #{fk.table.inspect}#{foreign_key_options(fk)}"
    end

    private def render_foreign_key(table : String, fk : ForeignKeyInfo) : String
      "s.add_foreign_key #{table.inspect}, #{fk.column.inspect}, #{fk.table.inspect}#{foreign_key_options(fk)}"
    end

    private def foreign_key_options(fk : ForeignKeyInfo) : String
      opts = [] of String
      opts << "on_delete: :#{fk.on_delete}" if fk.on_delete
      opts << "on_update: :#{fk.on_update}" if fk.on_update
      opts << "name: #{fk.name.inspect}" if fk.name
      opts << "primary_key: #{fk.ref_column.inspect}" unless fk.ref_column == "id"
      opts.empty? ? "" : ", #{opts.join(", ")}"
    end

    # `:tsvector`, `:"geometry(Point,4326)"`.
    private def symbol_literal(type : String) : String
      type.matches?(/\A[a-z_][a-z0-9_]*\z/) ? ":#{type}" : ":#{type.inspect}"
    end
  end

  # Holds the definition written in `db/schema.cr`; `silth db:schema:load` runs it.
  #
  # ```
  # Silth::DB::SchemaDefinition.define(version: 20261124120000) do |s|
  #   s.create_table "posts" do |t|
  #     t.id
  #     t.string "title", null: false
  #   end
  # end
  # ```
  class SchemaDefinition
    getter version : Int64
    getter connection : String?
    @block : Schema ->

    @@definitions = {} of String => SchemaDefinition

    def initialize(@version : Int64, @connection : String?, &@block : Schema ->)
    end

    def self.define(version : Int, connection : String? = nil, &block : Schema ->) : SchemaDefinition
      definition = new(version.to_i64, connection, &block)
      @@definitions[connection || ""] = definition
    end

    # The definition compiled in for *connection* (nil: the default connection).
    def self.for(connection : String) : SchemaDefinition?
      @@definitions[connection]? || (connection == DB.default ? @@definitions[""]? : nil)
    end

    # Drops every table, recreates the schema and marks the migrations up to
    # `version` as applied.
    def load(db : Database) : Nil
      migrator = Migrator.new(db)
      migrator.drop_all_tables
      schema = Schema.new(db)
      if db.dialect.supports_transactional_ddl?
        db.transaction { @block.call(schema) }
      else
        @block.call(schema)
      end
      versions = migrator.migrations_for_db.select { |m| m.version <= @version }.map(&.version)
      versions << @version if @version > 0 && !versions.includes?(@version)
      migrator.mark_applied(versions)
    end
  end
end

require "./schema_introspector"
