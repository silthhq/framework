module Silth::DB
  # SQL flavour differences between PostgreSQL, MySQL/MariaDB and SQLite.
  abstract class Dialect
    abstract def name : String
    abstract def quote(identifier : String) : String
    abstract def list_tables_sql : String
    abstract def column_type(type : Symbol, limit : Int32?, precision : Int32?, scale : Int32?, dimensions : Int32?) : String
    abstract def primary_key_sql(type : Symbol) : String

    def self.for(scheme : String) : Dialect
      case scheme
      when "postgres", "postgresql", "pg" then Postgres.new
      when "mysql", "mariadb"             then MySQL.new
      when "sqlite3", "sqlite"            then SQLite.new
      else                                     raise ConnectionError.new("No dialect for '#{scheme}'")
      end
    end

    # Converts `?` placeholders to the native syntax (outside quotes/comments).
    def prepare_sql(sql : String) : String
      sql
    end

    def quote_table(table : String) : String
      table.split('.').map { |p| p == "*" ? p : quote(p) }.join('.')
    end

    # Quotes `table.column` / `column` / `column AS alias`, leaves expressions alone.
    def quote_column(column : String) : String
      return column if column == "*" || column.includes?('(') || column.includes?(' ') || column.includes?('"') || column.includes?('`')
      column.split('.').map { |p| p == "*" ? p : quote(p) }.join('.')
    end

    def begin_sql : String
      "BEGIN"
    end

    def supports_returning? : Bool
      true
    end

    def supports_ilike? : Bool
      false
    end

    def supports_skip_locked? : Bool
      false
    end

    def supports_transactional_ddl? : Bool
      true
    end

    def now_sql : String
      "CURRENT_TIMESTAMP"
    end

    def random_sql : String
      "RANDOM()"
    end

    def bool(value : Bool) : String
      value ? "TRUE" : "FALSE"
    end

    def insert_ignore_sql(table : String, columns : String, placeholders : String) : String
      "INSERT INTO #{table} (#{columns}) VALUES #{placeholders} ON CONFLICT DO NOTHING"
    end

    def upsert_sql(table : String, columns : Array(String), rows : String, conflict : Array(String), update : Array(String)) : String
      updates = update.map { |c| "#{quote(c)} = excluded.#{quote(c)}" }.join(", ")
      action = update.empty? ? "DO NOTHING" : "DO UPDATE SET #{updates}"
      "INSERT INTO #{quote_table(table)} (#{columns.map { |c| quote(c) }.join(", ")}) VALUES #{rows} ON CONFLICT (#{conflict.map { |c| quote(c) }.join(", ")}) #{action}"
    end

    def json_extract(column : String, path : String) : String
      "json_extract(#{quote_column(column)}, '$.#{path.gsub("'", "")}')"
    end

    def case_insensitive_like(column : String) : String
      "LOWER(#{quote_column(column)}) LIKE LOWER(?)"
    end

    def default_timestamp : String
      "CURRENT_TIMESTAMP"
    end

    def drop_table_sql(table : String, if_exists : Bool, cascade : Bool) : String
      "DROP TABLE #{if_exists ? "IF EXISTS " : ""}#{quote_table(table)}"
    end
  end

  class Dialect::Postgres < Dialect
    def name : String
      "postgres"
    end

    def quote(identifier : String) : String
      %("#{identifier.gsub('"', "\"\"")}")
    end

    def prepare_sql(sql : String) : String
      return sql unless sql.includes?('?')
      n = 0
      String.build do |io|
        in_single = false
        in_double = false
        reader = Char::Reader.new(sql)
        while reader.has_next?
          c = reader.current_char
          if c == '\'' && !in_double
            in_single = !in_single
            io << c
          elsif c == '"' && !in_single
            in_double = !in_double
            io << c
          elsif c == '?' && !in_single && !in_double
            if reader.peek_next_char == '?'
              io << '?' # `??` escapes a literal `?` (jsonb operators)
              reader.next_char
            elsif reader.peek_next_char == '|' || reader.peek_next_char == '&'
              io << c
            else
              n += 1
              io << '$' << n
            end
          else
            io << c
          end
          reader.next_char
        end
      end
    end

    def list_tables_sql : String
      "SELECT tablename FROM pg_tables WHERE schemaname = current_schema() ORDER BY tablename"
    end

    def supports_ilike? : Bool
      true
    end

    def supports_skip_locked? : Bool
      true
    end

    def now_sql : String
      "NOW()"
    end

    def json_extract(column : String, path : String) : String
      parts = path.split('.')
      expr = quote_column(column)
      parts[0..-2].each { |p| expr += "->'#{p.gsub("'", "")}'" }
      "#{expr}->>'#{parts.last.gsub("'", "")}'"
    end

    def case_insensitive_like(column : String) : String
      "#{quote_column(column)} ILIKE ?"
    end

    def drop_table_sql(table : String, if_exists : Bool, cascade : Bool) : String
      super + (cascade ? " CASCADE" : "")
    end

    def primary_key_sql(type : Symbol) : String
      case type
      when :uuid then "UUID PRIMARY KEY DEFAULT gen_random_uuid()"
      when :int  then "INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY"
      else            "BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY"
      end
    end

    def column_type(type : Symbol, limit : Int32?, precision : Int32?, scale : Int32?, dimensions : Int32?) : String
      case type
      when :string     then "VARCHAR(#{limit || 255})"
      when :text       then "TEXT"
      when :integer    then "INTEGER"
      when :bigint     then "BIGINT"
      when :smallint   then "SMALLINT"
      when :float      then "DOUBLE PRECISION"
      when :real       then "REAL"
      when :decimal    then precision ? "NUMERIC(#{precision}, #{scale || 0})" : "NUMERIC"
      when :boolean    then "BOOLEAN"
      when :date       then "DATE"
      when :time       then "TIME"
      when :timestamp  then "TIMESTAMPTZ"
      when :json       then "JSONB"
      when :binary     then "BYTEA"
      when :uuid       then "UUID"
      when :vector     then "VECTOR(#{dimensions || 1536})"
      when :tsvector   then "TSVECTOR"
      when :inet       then "INET"
      when :citext     then "CITEXT"
      when :string_array  then "TEXT[]"
      when :integer_array then "BIGINT[]"
      when :float_array   then "DOUBLE PRECISION[]"
      else                    type.to_s
      end
    end
  end

  class Dialect::MySQL < Dialect
    def name : String
      "mysql"
    end

    def quote(identifier : String) : String
      "`#{identifier.gsub('`', "``")}`"
    end

    def list_tables_sql : String
      "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY table_name"
    end

    def supports_returning? : Bool
      false
    end

    def supports_skip_locked? : Bool
      true
    end

    def supports_transactional_ddl? : Bool
      false
    end

    def begin_sql : String
      "START TRANSACTION"
    end

    def random_sql : String
      "RAND()"
    end

    def now_sql : String
      "CURRENT_TIMESTAMP(6)"
    end

    def default_timestamp : String
      "CURRENT_TIMESTAMP(6)"
    end

    def bool(value : Bool) : String
      value ? "1" : "0"
    end

    def insert_ignore_sql(table : String, columns : String, placeholders : String) : String
      "INSERT IGNORE INTO #{table} (#{columns}) VALUES #{placeholders}"
    end

    def upsert_sql(table : String, columns : Array(String), rows : String, conflict : Array(String), update : Array(String)) : String
      cols = columns.map { |c| quote(c) }.join(", ")
      targets = update.empty? ? [conflict.first? || columns.first] : update
      updates = targets.map { |c| "#{quote(c)} = VALUES(#{quote(c)})" }.join(", ")
      "INSERT INTO #{quote_table(table)} (#{cols}) VALUES #{rows} ON DUPLICATE KEY UPDATE #{updates}"
    end

    def json_extract(column : String, path : String) : String
      "JSON_UNQUOTE(JSON_EXTRACT(#{quote_column(column)}, '$.#{path.gsub("'", "")}'))"
    end

    def primary_key_sql(type : Symbol) : String
      case type
      when :uuid then "CHAR(36) PRIMARY KEY"
      when :int  then "INT AUTO_INCREMENT PRIMARY KEY"
      else            "BIGINT AUTO_INCREMENT PRIMARY KEY"
      end
    end

    def column_type(type : Symbol, limit : Int32?, precision : Int32?, scale : Int32?, dimensions : Int32?) : String
      case type
      when :string    then "VARCHAR(#{limit || 255})"
      when :text      then "LONGTEXT"
      when :integer   then "INT"
      when :bigint    then "BIGINT"
      when :smallint  then "SMALLINT"
      when :float     then "DOUBLE"
      when :real      then "FLOAT"
      when :decimal   then "DECIMAL(#{precision || 10}, #{scale || 0})"
      when :boolean   then "TINYINT(1)"
      when :date      then "DATE"
      when :time      then "TIME"
      when :timestamp then "DATETIME(6)"
      when :json      then "JSON"
      when :binary    then "LONGBLOB"
      when :uuid      then "CHAR(36)"
      when :vector    then "JSON"
      when :inet      then "VARCHAR(45)"
      when :citext    then "VARCHAR(#{limit || 255})"
      when :string_array, :integer_array, :float_array then "JSON"
      when :tsvector  then raise Unsupported.new("tsvector columns require PostgreSQL; use a FULLTEXT index on MySQL")
      else                 type.to_s
      end
    end
  end

  class Dialect::SQLite < Dialect
    def name : String
      "sqlite"
    end

    def quote(identifier : String) : String
      %("#{identifier.gsub('"', "\"\"")}")
    end

    def list_tables_sql : String
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
    end

    def bool(value : Bool) : String
      value ? "1" : "0"
    end

    def begin_sql : String
      "BEGIN IMMEDIATE"
    end

    def primary_key_sql(type : Symbol) : String
      case type
      when :uuid then "TEXT PRIMARY KEY"
      else            "INTEGER PRIMARY KEY AUTOINCREMENT"
      end
    end

    def column_type(type : Symbol, limit : Int32?, precision : Int32?, scale : Int32?, dimensions : Int32?) : String
      case type
      when :string, :citext, :uuid, :inet then "VARCHAR(#{limit || 255})"
      when :text                          then "TEXT"
      when :integer, :bigint, :smallint   then "INTEGER"
      when :float, :real                  then "REAL"
      when :decimal                       then "NUMERIC"
      when :boolean                       then "BOOLEAN"
      when :date                          then "DATE"
      when :time                          then "TIME"
      when :timestamp                     then "DATETIME"
      when :json, :vector, :string_array, :integer_array, :float_array then "JSON"
      when :binary                        then "BLOB"
      when :tsvector                      then raise Unsupported.new("tsvector columns require PostgreSQL; SQLite offers FTS5 virtual tables")
      else                                     type.to_s
      end
    end
  end
end
