module Silth::DB
  # Reads tables back from the database catalog for `SchemaDumper`: one subclass
  # per database (pg_catalog, information_schema, SQLite pragmas).
  abstract class SchemaIntrospector
    alias Dumper = SchemaDumper

    NUMERIC_TYPES = %w(integer bigint smallint float real decimal int)
    NUMBER        = /\A-?\d+(?:\.\d+)?\z/

    def self.for(db : Database) : SchemaIntrospector
      case db.dialect.name
      when "postgres" then Postgres.new(db)
      when "mysql"    then MySQL.new(db)
      else                 SQLite.new(db)
      end
    end

    def initialize(@db : Database)
    end

    abstract def table(name : String) : Dumper::TableInfo

    # PostgreSQL extensions to enable before the tables.
    def extensions : Array(String)
      [] of String
    end

    # Foreign keys are added once every table exists (false: declared inline, SQLite).
    def add_foreign_keys_later? : Bool
      true
    end

    protected def rows(sql : String, *args) : Array(Array(Value))
      @db.query(sql, args.map { |a| a.as(Value) }.to_a).rows
    end

    # Crystal source for a literal default of a column of *type*.
    protected def literal(value : String, type : String) : String
      if type == "json" && value.in?("{}", "[]")
        value == "{}" ? ":empty_json" : ":empty_array"
      elsif type == "boolean" && value.in?("0", "1", "true", "false", "TRUE", "FALSE")
        value.in?("1", "true", "TRUE") ? "true" : "false"
      elsif NUMERIC_TYPES.includes?(type) && value.matches?(NUMBER)
        value
      else
        value.inspect
      end
    end

    protected def raw(sql : String) : String
      "Silth::DB::Raw.new(#{sql.inspect})"
    end

    # `'it''s'` → `it's`; nil when *sql* is not a single quoted string.
    protected def unquote(sql : String, cast : Regex? = nil) : String?
      pattern = cast ? /\A'((?:[^']|'')*)'#{cast}\z/ : /\A'((?:[^']|'')*)'\z/
      sql.match(pattern).try { |m| m[1].gsub("''", "'") }
    end

    protected def action(rule : String?) : Symbol?
      case rule.try(&.upcase)
      when "CASCADE", "C"     then :cascade
      when "SET NULL", "N"    then :nullify
      when "RESTRICT", "R"    then :restrict
      when "SET DEFAULT", "D" then :default
      else                         nil # NO ACTION, the default
      end
    end

    # --- PostgreSQL ------------------------------------------------------------

    class Postgres < SchemaIntrospector
      TYPES = {
        "bigint" => "bigint", "integer" => "integer", "smallint" => "smallint", "text" => "text",
        "double precision" => "float", "real" => "real", "boolean" => "boolean", "date" => "date",
        "time without time zone" => "time", "timestamp with time zone" => "timestamp", "jsonb" => "json",
        "bytea" => "binary", "uuid" => "uuid", "inet" => "inet", "citext" => "citext", "tsvector" => "tsvector",
        "text[]" => "string_array", "bigint[]" => "integer_array", "double precision[]" => "float_array",
        "numeric" => "decimal",
      }
      INDEX_DEF = /\ACREATE (UNIQUE )?INDEX (\S+) ON \S+ USING (\w+) \(([^()]+)\)(?: WHERE (.+))?\z/

      def extensions : Array(String)
        rows("SELECT extname FROM pg_extension WHERE extname <> 'plpgsql' ORDER BY extname").map(&.first.to_s)
      end

      def table(name : String) : Dumper::TableInfo
        ref = @db.dialect.quote_table(name)
        pk = primary_key(ref)
        id_type = nil
        columns = rows(<<-SQL, ref).map do |r|
          SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull, pg_get_expr(d.adbin, d.adrelid),
                 a.attidentity::text, a.attgenerated::text
          FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
          WHERE a.attrelid = ?::regclass AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum
          SQL
          col_name, sql_type, identity, default = r[0].to_s, r[1].to_s, r[4].to_s, r[3].try(&.to_s)
          id_type = id_type_for(sql_type, identity, default) if pk == [col_name]
          column(col_name, sql_type, r[2] == true, default, identity, r[5].to_s == "s")
        end
        indexes, raw_indexes = indexes(ref)
        unlogged = @db.scalar("SELECT relpersistence::text FROM pg_class WHERE oid = ?::regclass", [ref] of Value) == "u"
        Dumper::TableInfo.new(name, columns, pk, id_type, indexes, raw_indexes, foreign_keys(ref), unlogged)
      end

      private def primary_key(ref : String) : Array(String)
        rows(<<-SQL, ref).map(&.first.to_s)
          SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
          WHERE i.indrelid = ?::regclass AND i.indisprimary ORDER BY array_position(i.indkey::int2[], a.attnum)
          SQL
      end

      private def id_type_for(sql_type : String, identity : String, default : String?) : Symbol?
        if !identity.empty?
          return :bigint if sql_type == "bigint"
          return :int if sql_type == "integer"
        end
        :uuid if sql_type == "uuid" && default == "gen_random_uuid()"
      end

      private def column(name : String, sql_type : String, not_null : Bool, default : String?, identity : String, generated : Bool) : Dumper::ColumnInfo
        type, limit, precision, scale, dimensions = parse_type(sql_type)
        dflt = generated || !identity.empty? ? nil : default.try { |d| default_literal(d, type) }
        Dumper::ColumnInfo.new(name, type, !not_null, dflt, limit, precision, scale, dimensions, generated ? default : nil)
      end

      private def parse_type(sql : String) : {String, Int32?, Int32?, Int32?, Int32?}
        if m = sql.match(/\Acharacter varying\((\d+)\)\z/)
          {"string", m[1].to_i, nil, nil, nil}
        elsif m = sql.match(/\Anumeric\((\d+),(\d+)\)\z/)
          {"decimal", nil, m[1].to_i, m[2].to_i, nil}
        elsif m = sql.match(/\Avector\((\d+)\)\z/)
          {"vector", nil, nil, nil, m[1].to_i}
        else
          {TYPES[sql]? || Dumper.raw_type(sql), nil, nil, nil, nil}
        end
      end

      private def default_literal(sql : String, type : String) : String
        case sql
        when "CURRENT_TIMESTAMP", "now()" then ":now"
        when "gen_random_uuid()"          then ":uuid"
        when "'{}'::jsonb"                then ":empty_json"
        when "'[]'::jsonb"                then ":empty_array"
        when "true", "false"              then sql
        when NUMBER                       then literal(sql, type)
        else
          unquote(sql, /::[\w\s"\[\]]+/).try { |value| literal(value, type) } || raw(sql)
        end
      end

      private def indexes(ref : String) : {Array(Dumper::IndexInfo), Array(String)}
        indexes = [] of Dumper::IndexInfo
        raw_indexes = [] of String
        rows(<<-SQL, ref).each do |r|
          SELECT c.relname, pg_get_indexdef(i.indexrelid) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
          WHERE i.indrelid = ?::regclass AND NOT i.indisprimary ORDER BY c.relname
          SQL
          definition = r[1].to_s
          if index = parse_index(r[0].to_s, definition)
            indexes << index
          else
            raw_indexes << definition.sub(/ ON (?:"[^"]+"|\w+)\./, " ON ")
          end
        end
        {indexes, raw_indexes}
      end

      # Plain column indexes become `t.index`; expressions and sort orders stay SQL.
      private def parse_index(name : String, definition : String) : Dumper::IndexInfo?
        m = definition.match(INDEX_DEF) || return nil
        columns = [] of String
        opclasses = [] of String?
        m[4].split(", ").each do |item|
          part = item.match(/\A("(?:[^"]|"")+"|[\w$]+)(?: (\w+))?\z/) || return nil
          return nil if part[2]?.try(&.upcase.in?("ASC", "DESC", "NULLS"))
          columns << unquote_identifier(part[1])
          opclasses << part[2]?
        end
        return nil unless opclasses.uniq.size == 1
        using = m[3] == "btree" ? nil : m[3]
        Dumper::IndexInfo.new(name, columns, !m[1]?.nil?, using, m[5]?, opclasses.first)
      end

      private def unquote_identifier(name : String) : String
        name.starts_with?('"') ? name[1..-2].gsub("\"\"", "\"") : name
      end

      private def foreign_keys(ref : String) : Array(Dumper::ForeignKeyInfo)
        rows(<<-SQL, ref).map do |r|
          SELECT con.conname, a.attname, cl.relname, af.attname, con.confdeltype::text, con.confupdtype::text
          FROM pg_constraint con
          JOIN pg_class cl ON cl.oid = con.confrelid
          JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = con.conkey[1]
          JOIN pg_attribute af ON af.attrelid = con.confrelid AND af.attnum = con.confkey[1]
          WHERE con.contype = 'f' AND con.conrelid = ?::regclass ORDER BY con.conname
          SQL
          Dumper::ForeignKeyInfo.new(r[0].to_s, r[1].to_s, r[2].to_s, r[3].to_s, action(r[4].to_s), action(r[5].to_s))
        end
      end
    end

    # --- MySQL / MariaDB -------------------------------------------------------

    class MySQL < SchemaIntrospector
      TYPES = {
        "bigint" => "bigint", "int" => "integer", "smallint" => "smallint", "tinyint(1)" => "boolean",
        "double" => "float", "float" => "real", "longtext" => "text", "date" => "date", "time" => "time",
        "datetime(6)" => "timestamp", "json" => "json", "longblob" => "binary", "char(36)" => "uuid",
      }

      @mariadb : Bool

      def initialize(@db : Database)
        @mariadb = @db.scalar("SELECT VERSION()").to_s.includes?("MariaDB")
      end

      def table(name : String) : Dumper::TableInfo
        pk = rows(<<-SQL, name).map(&.first.to_s)
          SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE
          WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND CONSTRAINT_NAME = 'PRIMARY' ORDER BY ORDINAL_POSITION
          SQL
        json_columns = @mariadb ? mariadb_json_columns(name) : [] of String
        id_type = nil
        columns = rows(<<-SQL, name).map do |r|
          SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, EXTRA, COLUMN_COMMENT, GENERATION_EXPRESSION
          FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION
          SQL
          col_name, column_type, extra = r[0].to_s, r[1].to_s, r[4].to_s
          type, limit, precision, scale = parse_type(column_type)
          type = "json" if json_columns.includes?(col_name)
          id_type = id_type_for(type, extra) if pk == [col_name]
          generated = r[6].to_s.presence
          default = generated ? nil : r[3].try { |d| default_literal(d.to_s, type, extra) }
          Dumper::ColumnInfo.new(col_name, type, r[2].to_s == "YES", default, limit, precision, scale, nil,
            generated, comment: r[5].to_s.presence)
        end
        Dumper::TableInfo.new(name, columns, pk, id_type, indexes(name), [] of String, foreign_keys(name))
      end

      private def parse_type(column_type : String) : {String, Int32?, Int32?, Int32?}
        sql = column_type.sub(/\A(bigint|int|smallint|mediumint)\(\d+\)/, "\\1") # MariaDB display widths
        if m = sql.match(/\Avarchar\((\d+)\)\z/)
          {"string", m[1].to_i, nil, nil}
        elsif m = sql.match(/\Adecimal\((\d+),(\d+)\)\z/)
          {"decimal", nil, m[1].to_i, m[2].to_i}
        else
          {TYPES[sql]? || Dumper.raw_type(sql), nil, nil, nil}
        end
      end

      private def id_type_for(type : String, extra : String) : Symbol?
        if extra.includes?("auto_increment")
          return :bigint if type == "bigint"
          return :int if type == "integer"
        end
        :uuid if type == "uuid"
      end

      # MySQL reports literals bare and flags expressions with DEFAULT_GENERATED;
      # MariaDB quotes literals, writes expressions bare and reports NULL as `NULL`.
      private def default_literal(value : String, type : String, extra : String) : String?
        if @mariadb
          return nil if value == "NULL"
          return unquote(value).try { |v| literal(v.gsub("\\\\", "\\"), type) } || expression_default(value) if value.starts_with?('\'')
          return literal(value, type) if value.matches?(NUMBER)
          expression_default(value)
        elsif extra.includes?("DEFAULT_GENERATED")
          expression_default(value)
        else
          literal(value, type)
        end
      end

      private def expression_default(sql : String) : String
        case sql
        when /\Acurrent_timestamp(\(\d\))?\z/i then ":now"
        when "_utf8mb4\\'{}\\'", "'{}'"        then ":empty_json"
        when "_utf8mb4\\'[]\\'", "'[]'"        then ":empty_array"
        else                                        raw("(#{sql})")
        end
      end

      # MariaDB stores JSON as LONGTEXT with a json_valid() check.
      private def mariadb_json_columns(table : String) : Array(String)
        rows(<<-SQL, table).compact_map { |r| r[0].to_s.match(/\Ajson_valid\(`([^`]+)`\)\z/).try(&.[1]) }
          SELECT CHECK_CLAUSE FROM information_schema.CHECK_CONSTRAINTS WHERE CONSTRAINT_SCHEMA = DATABASE() AND TABLE_NAME = ?
          SQL
      end

      private def indexes(table : String) : Array(Dumper::IndexInfo)
        grouped = {} of String => {Bool, Bool, Array(String)}
        rows(<<-SQL, table).each do |r|
          SELECT INDEX_NAME, NON_UNIQUE, COLUMN_NAME, INDEX_TYPE FROM information_schema.STATISTICS
          WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND INDEX_NAME <> 'PRIMARY' ORDER BY INDEX_NAME, SEQ_IN_INDEX
          SQL
          entry = grouped[r[0].to_s] ||= {DB.as_i64(r[1]) == 0, r[3].to_s == "FULLTEXT", [] of String}
          entry[2] << r[2].to_s
        end
        grouped.map do |index_name, (unique, fulltext, columns)|
          Dumper::IndexInfo.new(index_name, columns, unique, fulltext: fulltext)
        end
      end

      private def foreign_keys(table : String) : Array(Dumper::ForeignKeyInfo)
        rows(<<-SQL, table).map do |r|
          SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME, r.DELETE_RULE, r.UPDATE_RULE
          FROM information_schema.KEY_COLUMN_USAGE k
          JOIN information_schema.REFERENTIAL_CONSTRAINTS r
            ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME AND r.TABLE_NAME = k.TABLE_NAME
          WHERE k.TABLE_SCHEMA = DATABASE() AND k.TABLE_NAME = ? AND k.REFERENCED_TABLE_NAME IS NOT NULL
          ORDER BY k.CONSTRAINT_NAME
          SQL
          Dumper::ForeignKeyInfo.new(r[0].to_s, r[1].to_s, r[2].to_s, r[3].to_s, action(r[4].to_s), action(r[5].to_s))
        end
      end
    end

    # --- SQLite ----------------------------------------------------------------

    class SQLite < SchemaIntrospector
      TYPES = {
        "TEXT" => "text", "INTEGER" => "integer", "REAL" => "float", "NUMERIC" => "decimal", "BOOLEAN" => "boolean",
        "DATE" => "date", "TIME" => "time", "DATETIME" => "timestamp", "JSON" => "json", "BLOB" => "binary",
      }

      def add_foreign_keys_later? : Bool
        false
      end

      def table(name : String) : Dumper::TableInfo
        create_sql = @db.scalar("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [name] of Value).to_s
        info = rows(%(SELECT name, type, "notnull", dflt_value, pk FROM pragma_table_info(?) ORDER BY cid), name)
        pk = info.select { |r| DB.as_i64(r[4]) > 0 }.sort_by { |r| DB.as_i64(r[4]) }.map(&.[0].to_s)
        indexes, raw_indexes, unique_columns = indexes(name)
        id_type = nil
        columns = info.map do |r|
          col_name, declared = r[0].to_s, r[1].to_s
          type, limit = parse_type(declared)
          if pk == [col_name]
            id_type = :bigint if declared.upcase == "INTEGER" && create_sql.upcase.includes?("AUTOINCREMENT")
            id_type = :uuid if declared.upcase == "TEXT"
          end
          default = r[3].try { |d| default_literal(d.to_s, type) }
          Dumper::ColumnInfo.new(col_name, type, DB.as_i64(r[2]) == 0, default, limit, unique: unique_columns.includes?(col_name))
        end
        Dumper::TableInfo.new(name, columns, pk, id_type, indexes, raw_indexes, foreign_keys(name))
      end

      private def parse_type(declared : String) : {String, Int32?}
        if m = declared.match(/\AVARCHAR\((\d+)\)\z/i)
          {"string", m[1].to_i}
        else
          {TYPES[declared.upcase]? || Dumper.raw_type(declared), nil}
        end
      end

      private def default_literal(sql : String, type : String) : String?
        case sql
        when "NULL"                   then nil
        when /\ACURRENT_TIMESTAMP\z/i then ":now"
        when "('{}')"                 then ":empty_json"
        when "('[]')"                 then ":empty_array"
        when NUMBER                   then literal(sql, type)
        else                               unquote(sql).try { |value| literal(value, type) } || raw(sql)
        end
      end

      # Indexes, partial/expression indexes kept as SQL, and single columns declared UNIQUE.
      private def indexes(table : String) : {Array(Dumper::IndexInfo), Array(String), Array(String)}
        indexes = [] of Dumper::IndexInfo
        raw_indexes = [] of String
        unique_columns = [] of String
        rows(%(SELECT name, "unique", origin, partial FROM pragma_index_list(?) ORDER BY name), table).each do |r|
          index_name, unique, origin = r[0].to_s, DB.as_i64(r[1]) == 1, r[2].to_s
          next if origin == "pk"
          columns = rows("SELECT name FROM pragma_index_info(?) ORDER BY seqno", index_name).map(&.first)
          if DB.as_i64(r[3]) == 1 || columns.any?(&.nil?)
            raw_indexes << @db.scalar("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?", [index_name] of Value).to_s
          elsif origin == "u" && columns.size == 1
            unique_columns << columns.first.to_s
          else
            names = columns.map(&.to_s)
            index_name = Schema.index_name(table, names) if origin == "u" # sqlite_autoindex_* names are reserved
            indexes << Dumper::IndexInfo.new(index_name, names, unique)
          end
        end
        {indexes, raw_indexes, unique_columns}
      end

      private def foreign_keys(table : String) : Array(Dumper::ForeignKeyInfo)
        rows(%(SELECT "table", "from", "to", on_update, on_delete FROM pragma_foreign_key_list(?) ORDER BY "from", seq), table).map do |r|
          Dumper::ForeignKeyInfo.new(nil, r[1].to_s, r[0].to_s, r[2].to_s, action(r[4].to_s), action(r[3].to_s))
        end
      end
    end
  end
end
