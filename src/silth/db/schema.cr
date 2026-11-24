module Silth::DB
  # Column definition used by the schema builder.
  class ColumnDef
    property name : String
    property type : Symbol
    property null : Bool = true
    property default : String? = nil
    property limit : Int32? = nil
    property precision : Int32? = nil
    property scale : Int32? = nil
    property dimensions : Int32? = nil
    property unique : Bool = false
    property primary : Bool = false
    property generated : String? = nil
    property comment : String? = nil
    property references : {String, String, String}? = nil

    def initialize(@name : String, @type : Symbol)
    end

    def to_sql(dialect : Dialect) : String
      if @primary
        return "#{dialect.quote(@name)} #{dialect.primary_key_sql(@type)}"
      end
      String.build do |io|
        io << dialect.quote(@name) << ' ' << dialect.column_type(@type, @limit, @precision, @scale, @dimensions)
        if gen = @generated
          io << " GENERATED ALWAYS AS (" << gen << ") STORED"
        else
          io << " NOT NULL" unless @null
          io << " DEFAULT " << @default if @default
          io << " UNIQUE" if @unique
        end
        io << " COMMENT '" << @comment.not_nil!.gsub("'", "''") << "'" if @comment && dialect.name == "mysql"
      end
    end
  end

  record IndexDef, columns : Array(String), unique : Bool, name : String, using : String?, where : String?, opclass : String?

  record ForeignKeyDef, column : String, table : String, ref_column : String, on_delete : String?, on_update : String?

  # Converts a Crystal default into a SQL literal.
  module Literal
    def self.to_sql(value, dialect : Dialect) : String
      case value
      when Nil    then "NULL"
      when Bool   then dialect.bool(value)
      when Number then value.to_s
      when Symbol
        case value
        when :now          then dialect.default_timestamp
        when :uuid         then dialect.name == "postgres" ? "gen_random_uuid()" : "NULL"
        when :empty_json   then dialect.name == "postgres" ? "'{}'::jsonb" : "('{}')"
        when :empty_array  then dialect.name == "postgres" ? "'[]'::jsonb" : "('[]')"
        else                    value.to_s
        end
      else "'#{value.to_s.gsub("'", "''")}'"
      end
    end
  end

  # Table definition DSL used by `create_table`.
  #
  # ```
  # create_table :posts do |t|
  #   t.id
  #   t.references :user, on_delete: :cascade
  #   t.string :title, null: false
  #   t.text :body
  #   t.boolean :published, default: false
  #   t.jsonb :metadata, default: :empty_json
  #   t.vector :embedding, 1536
  #   t.tsvector :search, from: [:title, :body]
  #   t.timestamps
  #   t.index [:user_id, :published]
  #   t.index :embedding, using: "hnsw", opclass: "vector_cosine_ops"
  # end
  # ```
  class TableBuilder
    getter name : String
    getter columns = [] of ColumnDef
    getter indexes = [] of IndexDef
    getter foreign_keys = [] of ForeignKeyDef
    getter dialect : Dialect

    def initialize(@name : String, @dialect : Dialect)
    end

    def column(name : String | Symbol, type : Symbol, null : Bool = true, default = nil, limit : Int32? = nil,
               precision : Int32? = nil, scale : Int32? = nil, unique : Bool = false, index : Bool = false,
               dimensions : Int32? = nil, comment : String? = nil) : ColumnDef
      col = ColumnDef.new(name.to_s, type)
      col.null = null
      col.default = default.nil? ? nil : Literal.to_sql(default, @dialect)
      col.limit = limit
      col.precision = precision
      col.scale = scale
      col.unique = unique
      col.dimensions = dimensions
      col.comment = comment
      @columns << col
      self.index(name) if index
      col
    end

    # Auto-increment BIGINT primary key (or `t.id :uuid`).
    def id(type : Symbol = :bigint, name : String | Symbol = "id") : ColumnDef
      col = ColumnDef.new(name.to_s, type)
      col.primary = true
      @columns << col
      col
    end

    {% for t in %w(string text integer bigint smallint float real boolean date time binary uuid inet citext json string_array integer_array float_array) %}
      def {{t.id}}(name : String | Symbol, null : Bool = true, default = nil, limit : Int32? = nil, unique : Bool = false, index : Bool = false, comment : String? = nil) : ColumnDef
        column(name, :{{t.id}}, null: null, default: default, limit: limit, unique: unique, index: index, comment: comment)
      end
    {% end %}

    def jsonb(name : String | Symbol, null : Bool = true, default = nil, index : Bool = false) : ColumnDef
      column(name, :json, null: null, default: default, index: index)
    end

    def timestamp(name : String | Symbol, null : Bool = true, default = nil, index : Bool = false) : ColumnDef
      column(name, :timestamp, null: null, default: default, index: index)
    end

    def datetime(name : String | Symbol, null : Bool = true, default = nil, index : Bool = false) : ColumnDef
      timestamp(name, null, default, index)
    end

    def decimal(name : String | Symbol, precision : Int32 = 10, scale : Int32 = 2, null : Bool = true, default = nil) : ColumnDef
      column(name, :decimal, null: null, default: default, precision: precision, scale: scale)
    end

    # pgvector column (JSON on other databases).
    def vector(name : String | Symbol, dimensions : Int32 = 1536, null : Bool = true) : ColumnDef
      column(name, :vector, null: null, dimensions: dimensions)
    end

    # Generated full-text column (PostgreSQL) with an automatic GIN index.
    def tsvector(name : String | Symbol, from : Array(String | Symbol), language : String = "english", index : Bool = true) : ColumnDef
      col = ColumnDef.new(name.to_s, :tsvector)
      parts = from.map { |c| "coalesce(#{@dialect.quote(c.to_s)}, '')" }.join(" || ' ' || ")
      col.generated = "to_tsvector('#{language.gsub("'", "")}', #{parts})"
      @columns << col
      self.index(name, using: "gin") if index
      col
    end

    # `t.references :user` → `user_id BIGINT NOT NULL` + foreign key + index.
    def references(name : String | Symbol, null : Bool = false, foreign_key : Bool = true, to_table : String? = nil,
                   on_delete : Symbol? = :cascade, index : Bool = true, type : Symbol = :bigint) : ColumnDef
      column_name = name.to_s.ends_with?("_id") ? name.to_s : "#{name}_id"
      col = column(column_name, type, null: null)
      table = to_table || Inflector.pluralize(name.to_s.rchop("_id"))
      @foreign_keys << ForeignKeyDef.new(column_name, table, "id", on_delete.try { |d| Schema.referential_action(d) }, nil) if foreign_key
      self.index(column_name) if index
      col
    end

    def belongs_to(name : String | Symbol, **opts) : ColumnDef
      references(name, **opts)
    end

    def timestamps(null : Bool = true) : Nil
      timestamp(:created_at, null: null, default: null ? nil : :now)
      timestamp(:updated_at, null: null, default: null ? nil : :now)
    end

    def soft_deletes : Nil
      timestamp(:deleted_at, index: true)
    end

    def index(columns : String | Symbol | Array, unique : Bool = false, name : String? = nil, using : String? = nil,
              where : String? = nil, opclass : String? = nil) : Nil
      cols = columns.is_a?(Array) ? columns.map(&.to_s) : [columns.to_s]
      index_name = name || "index_#{@name}_on_#{cols.join("_and_")}"
      @indexes << IndexDef.new(cols, unique, index_name, using, where, opclass)
    end

    # Full-text index usable by `search`: FULLTEXT on MySQL/MariaDB, GIN on PostgreSQL, no-op on SQLite.
    def fulltext(columns : Array(String | Symbol) | String | Symbol, language : String = "english", name : String? = nil) : Nil
      cols = columns.is_a?(Array) ? columns.map(&.to_s) : [columns.to_s]
      @indexes << IndexDef.new(cols, false, name || "fulltext_#{@name}_on_#{cols.join("_and_")}", "fulltext", nil, language)
    end

    def unique(columns : String | Symbol | Array, name : String? = nil) : Nil
      index(columns, unique: true, name: name)
    end

    def to_create_sql(if_not_exists : Bool = false) : Array(String)
      defs = @columns.map(&.to_sql(@dialect))
      @foreign_keys.each do |fk|
        clause = "FOREIGN KEY (#{@dialect.quote(fk.column)}) REFERENCES #{@dialect.quote_table(fk.table)} (#{@dialect.quote(fk.ref_column)})"
        clause += " ON DELETE #{fk.on_delete}" if fk.on_delete
        defs << clause
      end
      statements = ["CREATE TABLE #{if_not_exists ? "IF NOT EXISTS " : ""}#{@dialect.quote_table(@name)} (\n  #{defs.join(",\n  ")}\n)"]
      @indexes.each { |idx| Schema.index_sql(@dialect, @name, idx).try { |sql| statements << sql } }
      statements
    end
  end

  # Schema manipulation, available inside migrations.
  class Schema
    getter db : Database

    def initialize(@db : Database = DB.connection)
    end

    def dialect : Dialect
      @db.dialect
    end

    def execute(sql : String) : Nil
      @db.exec_script(sql)
    end

    def create_table(name : String | Symbol, if_not_exists : Bool = false, & : TableBuilder ->) : Nil
      builder = TableBuilder.new(name.to_s, dialect)
      yield builder
      builder.to_create_sql(if_not_exists).each { |sql| @db.query(sql) }
    end

    def drop_table(name : String | Symbol, if_exists : Bool = true, cascade : Bool = false) : Nil
      @db.query(dialect.drop_table_sql(name.to_s, if_exists, cascade))
    end

    def rename_table(from : String | Symbol, to : String | Symbol) : Nil
      @db.query("ALTER TABLE #{dialect.quote_table(from.to_s)} RENAME TO #{dialect.quote_table(to.to_s)}")
    end

    def add_column(table : String | Symbol, name : String | Symbol, type : Symbol, **opts) : Nil
      builder = TableBuilder.new(table.to_s, dialect)
      col = builder.column(name, type, **opts)
      @db.query("ALTER TABLE #{dialect.quote_table(table.to_s)} ADD COLUMN #{col.to_sql(dialect)}")
      builder.indexes.each { |idx| Schema.index_sql(dialect, table.to_s, idx).try { |sql| @db.query(sql) } }
    end

    def remove_column(table : String | Symbol, name : String | Symbol) : Nil
      @db.query("ALTER TABLE #{dialect.quote_table(table.to_s)} DROP COLUMN #{dialect.quote(name.to_s)}")
    end

    def rename_column(table : String | Symbol, from : String | Symbol, to : String | Symbol) : Nil
      @db.query("ALTER TABLE #{dialect.quote_table(table.to_s)} RENAME COLUMN #{dialect.quote(from.to_s)} TO #{dialect.quote(to.to_s)}")
    end

    def change_column(table : String | Symbol, name : String | Symbol, type : Symbol, null : Bool = true, limit : Int32? = nil) : Nil
      sql_type = dialect.column_type(type, limit, nil, nil, nil)
      case dialect.name
      when "postgres"
        @db.query("ALTER TABLE #{dialect.quote_table(table.to_s)} ALTER COLUMN #{dialect.quote(name.to_s)} TYPE #{sql_type}")
        @db.query("ALTER TABLE #{dialect.quote_table(table.to_s)} ALTER COLUMN #{dialect.quote(name.to_s)} #{null ? "DROP" : "SET"} NOT NULL")
      when "mysql"
        @db.query("ALTER TABLE #{dialect.quote_table(table.to_s)} MODIFY #{dialect.quote(name.to_s)} #{sql_type}#{null ? "" : " NOT NULL"}")
      else
        raise Unsupported.new("SQLite cannot change column types in place; create a new table and copy the data")
      end
    end

    def add_index(table : String | Symbol, columns : String | Symbol | Array, unique : Bool = false, name : String? = nil,
                  using : String? = nil, where : String? = nil, opclass : String? = nil) : Nil
      builder = TableBuilder.new(table.to_s, dialect)
      builder.index(columns, unique: unique, name: name, using: using, where: where, opclass: opclass)
      Schema.index_sql(dialect, table.to_s, builder.indexes.first).try { |sql| @db.query(sql) }
    end

    def remove_index(table : String | Symbol, name : String) : Nil
      sql = dialect.name == "mysql" ? "DROP INDEX #{dialect.quote(name)} ON #{dialect.quote_table(table.to_s)}" : "DROP INDEX #{dialect.quote(name)}"
      @db.query(sql)
    end

    def add_foreign_key(table : String | Symbol, column : String | Symbol, to_table : String | Symbol, on_delete : Symbol? = nil) : Nil
      raise Unsupported.new("SQLite cannot add foreign keys to existing tables") if dialect.name == "sqlite"
      sql = "ALTER TABLE #{dialect.quote_table(table.to_s)} ADD FOREIGN KEY (#{dialect.quote(column.to_s)}) REFERENCES #{dialect.quote_table(to_table.to_s)} (#{dialect.quote("id")})"
      sql += " ON DELETE #{Schema.referential_action(on_delete)}" if on_delete
      @db.query(sql)
    end

    # PostgreSQL extensions (`vector`, `pg_trgm`, `citext`…). No-op on other databases.
    def enable_extension(name : String) : Nil
      @db.query("CREATE EXTENSION IF NOT EXISTS #{dialect.quote(name)}") if dialect.name == "postgres"
    end

    def table_exists?(name : String | Symbol) : Bool
      @db.table_exists?(name.to_s)
    end

    def self.referential_action(action : Symbol) : String
      case action
      when :nullify   then "SET NULL"
      when :restrict  then "RESTRICT"
      when :no_action then "NO ACTION"
      when :default   then "SET DEFAULT"
      else                 "CASCADE"
      end
    end

    def self.index_sql(dialect : Dialect, table : String, idx : IndexDef) : String?
      if idx.using == "fulltext"
        case dialect.name
        when "mysql"
          return "CREATE FULLTEXT INDEX #{dialect.quote(idx.name)} ON #{dialect.quote_table(table)} (#{idx.columns.map { |c| dialect.quote(c) }.join(", ")})"
        when "postgres"
          lang = (idx.opclass || "english").gsub("'", "")
          expr = idx.columns.map { |c| "coalesce(#{dialect.quote(c)}::text, '')" }.join(" || ' ' || ")
          return "CREATE INDEX IF NOT EXISTS #{dialect.quote(idx.name)} ON #{dialect.quote_table(table)} USING gin (to_tsvector('#{lang}', #{expr}))"
        else
          return nil
        end
      end
      cols = idx.columns.map { |c| dialect.quote(c) + (idx.opclass ? " #{idx.opclass}" : "") }.join(", ")
      String.build do |io|
        io << "CREATE " << (idx.unique ? "UNIQUE " : "") << "INDEX "
        io << "IF NOT EXISTS " unless dialect.name == "mysql"
        io << dialect.quote(idx.name) << " ON " << dialect.quote_table(table)
        if (using = idx.using) && dialect.name == "postgres"
          io << " USING " << using
        end
        io << " (" << cols << ")"
        io << " WHERE " << idx.where if idx.where && dialect.name != "mysql"
      end
    end
  end
end
