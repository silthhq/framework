@[Link("sqlite3")]
lib LibSQLite3
  type Sqlite3 = Void*
  type Stmt = Void*

  OK       =   0
  ROW      = 100
  DONE     = 101
  INTEGER  =   1
  FLOAT    =   2
  TEXT     =   3
  BLOB     =   4
  NULL     =   5

  OPEN_READWRITE = 0x00000002
  OPEN_CREATE    = 0x00000004
  OPEN_URI       = 0x00000040
  OPEN_FULLMUTEX = 0x00010000

  fun open_v2 = sqlite3_open_v2(filename : UInt8*, db : Sqlite3*, flags : Int32, vfs : UInt8*) : Int32
  fun close_v2 = sqlite3_close_v2(db : Sqlite3) : Int32
  fun errmsg = sqlite3_errmsg(db : Sqlite3) : UInt8*
  fun extended_errcode = sqlite3_extended_errcode(db : Sqlite3) : Int32
  fun busy_timeout = sqlite3_busy_timeout(db : Sqlite3, ms : Int32) : Int32
  fun exec = sqlite3_exec(db : Sqlite3, sql : UInt8*, callback : Void*, arg : Void*, errmsg : UInt8**) : Int32
  fun free = sqlite3_free(ptr : Void*)
  fun prepare_v2 = sqlite3_prepare_v2(db : Sqlite3, sql : UInt8*, nbyte : Int32, stmt : Stmt*, tail : UInt8**) : Int32
  fun step = sqlite3_step(stmt : Stmt) : Int32
  fun finalize = sqlite3_finalize(stmt : Stmt) : Int32
  fun bind_null = sqlite3_bind_null(stmt : Stmt, idx : Int32) : Int32
  fun bind_int64 = sqlite3_bind_int64(stmt : Stmt, idx : Int32, value : Int64) : Int32
  fun bind_double = sqlite3_bind_double(stmt : Stmt, idx : Int32, value : Float64) : Int32
  fun bind_text = sqlite3_bind_text(stmt : Stmt, idx : Int32, value : UInt8*, n : Int32, destructor : Void*) : Int32
  fun bind_blob = sqlite3_bind_blob(stmt : Stmt, idx : Int32, value : Void*, n : Int32, destructor : Void*) : Int32
  fun bind_parameter_count = sqlite3_bind_parameter_count(stmt : Stmt) : Int32
  fun column_count = sqlite3_column_count(stmt : Stmt) : Int32
  fun column_name = sqlite3_column_name(stmt : Stmt, idx : Int32) : UInt8*
  fun column_decltype = sqlite3_column_decltype(stmt : Stmt, idx : Int32) : UInt8*
  fun column_type = sqlite3_column_type(stmt : Stmt, idx : Int32) : Int32
  fun column_int64 = sqlite3_column_int64(stmt : Stmt, idx : Int32) : Int64
  fun column_double = sqlite3_column_double(stmt : Stmt, idx : Int32) : Float64
  fun column_text = sqlite3_column_text(stmt : Stmt, idx : Int32) : UInt8*
  fun column_blob = sqlite3_column_blob(stmt : Stmt, idx : Int32) : Void*
  fun column_bytes = sqlite3_column_bytes(stmt : Stmt, idx : Int32) : Int32
  fun changes = sqlite3_changes(db : Sqlite3) : Int32
  fun last_insert_rowid = sqlite3_last_insert_rowid(db : Sqlite3) : Int64
  fun libversion = sqlite3_libversion : UInt8*
end

module Silth::DB::SQLite
  TRANSIENT = Pointer(Void).new(UInt64::MAX)

  def self.version : String
    String.new(LibSQLite3.libversion)
  end

  # SQLite connection through the system libsqlite3 (WAL mode, foreign keys on).
  class Connection < Silth::DB::Connection
    @db : LibSQLite3::Sqlite3
    @closed = false
    @dialect = Dialect::SQLite.new
    @mutex = Mutex.new

    def initialize(url : URI)
      path = url.path.presence || url.host.presence || ":memory:"
      path = path.lchop("//")
      unless path == ":memory:" || path.starts_with?("file:")
        dir = File.dirname(path)
        Dir.mkdir_p(dir) unless dir.empty? || Dir.exists?(dir)
      end
      flags = LibSQLite3::OPEN_READWRITE | LibSQLite3::OPEN_CREATE | LibSQLite3::OPEN_URI | LibSQLite3::OPEN_FULLMUTEX
      rc = LibSQLite3.open_v2(path, out db, flags, nil)
      @db = db
      raise ConnectionError.new("Unable to open SQLite database #{path}: #{error_message}") unless rc == LibSQLite3::OK
      LibSQLite3.busy_timeout(@db, (url.query_params["busy_timeout"]? || "5000").to_i)
      pragmas = ["PRAGMA foreign_keys = ON"]
      unless path == ":memory:"
        pragmas << "PRAGMA journal_mode = WAL"
        pragmas << "PRAGMA synchronous = NORMAL"
      end
      exec_script(pragmas.join(";"))
    end

    def dialect : Dialect
      @dialect
    end

    def closed? : Bool
      @closed
    end

    def close : Nil
      return if @closed
      @closed = true
      LibSQLite3.close_v2(@db)
    end

    def exec_script(sql : String) : Nil
      @mutex.synchronize do
        rc = LibSQLite3.exec(@db, sql, nil, nil, out err)
        unless rc == LibSQLite3::OK
          message = err.null? ? error_message : String.new(err)
          LibSQLite3.free(err.as(Void*)) unless err.null?
          raise build_error(message, sql)
        end
      end
    end

    def query(sql : String, args : Array(Value)) : ResultSet
      @mutex.synchronize { run(sql, args) }
    end

    private def run(sql : String, args : Array(Value)) : ResultSet
      rc = LibSQLite3.prepare_v2(@db, sql, sql.bytesize, out stmt, nil)
      raise build_error(error_message, sql) unless rc == LibSQLite3::OK
      begin
        args.each_with_index { |arg, i| bind(stmt, i + 1, arg) }
        count = LibSQLite3.column_count(stmt)
        columns = Array(String).new(count) { |i| String.new(LibSQLite3.column_name(stmt, i)) }
        decltypes = Array(String).new(count) do |i|
          ptr = LibSQLite3.column_decltype(stmt, i)
          ptr.null? ? "" : String.new(ptr).upcase
        end
        rows = [] of Array(Value)
        loop do
          rc = LibSQLite3.step(stmt)
          case rc
          when LibSQLite3::ROW
            rows << Array(Value).new(count) { |i| read(stmt, i, decltypes[i]) }
          when LibSQLite3::DONE
            break
          else
            raise build_error(error_message, sql)
          end
        end
        result = ResultSet.new(columns, rows)
        result.rows_affected = LibSQLite3.changes(@db).to_i64
        result.last_insert_id = LibSQLite3.last_insert_rowid(@db)
        result
      ensure
        LibSQLite3.finalize(stmt)
      end
    end

    private def bind(stmt, idx : Int32, value : Value) : Nil
      case value
      when Nil     then LibSQLite3.bind_null(stmt, idx)
      when Bool    then LibSQLite3.bind_int64(stmt, idx, value ? 1_i64 : 0_i64)
      when Int32   then LibSQLite3.bind_int64(stmt, idx, value.to_i64)
      when Int64   then LibSQLite3.bind_int64(stmt, idx, value)
      when Float32 then LibSQLite3.bind_double(stmt, idx, value.to_f64)
      when Float64 then LibSQLite3.bind_double(stmt, idx, value)
      when String  then LibSQLite3.bind_text(stmt, idx, value, value.bytesize, TRANSIENT)
      when Bytes   then LibSQLite3.bind_blob(stmt, idx, value.to_unsafe.as(Void*), value.size, TRANSIENT)
      when Time
        text = DB.format_time(value)
        LibSQLite3.bind_text(stmt, idx, text, text.bytesize, TRANSIENT)
      when ::Silth::Decimal, ::Silth::Date
        text = value.to_s
        LibSQLite3.bind_text(stmt, idx, text, text.bytesize, TRANSIENT)
      else
        text = value.to_json
        LibSQLite3.bind_text(stmt, idx, text, text.bytesize, TRANSIENT)
      end
    end

    private def read(stmt, i : Int32, decltype : String) : Value
      case LibSQLite3.column_type(stmt, i)
      when LibSQLite3::NULL
        nil
      when LibSQLite3::INTEGER
        v = LibSQLite3.column_int64(stmt, i)
        decltype.starts_with?("BOOL") ? v != 0 : v
      when LibSQLite3::FLOAT
        LibSQLite3.column_double(stmt, i)
      when LibSQLite3::BLOB
        size = LibSQLite3.column_bytes(stmt, i)
        ptr = LibSQLite3.column_blob(stmt, i).as(UInt8*)
        Bytes.new(size).tap { |b| b.copy_from(ptr, size) }
      else
        ptr = LibSQLite3.column_text(stmt, i)
        text = String.new(ptr, LibSQLite3.column_bytes(stmt, i))
        if (decltype.starts_with?("DATETIME") || decltype.starts_with?("TIMESTAMP") || decltype == "DATE") && !text.empty?
          DB.parse_time(text) rescue text
        else
          text
        end
      end
    end

    private def error_message : String
      String.new(LibSQLite3.errmsg(@db))
    end

    private def build_error(message : String, sql : String) : QueryError
      code = LibSQLite3.extended_errcode(@db)
      full = "#{message} (SQL: #{sql[0, 500]})"
      case code
      when 2067, 1555 then UniqueViolation.new(full, code.to_s, sql)
      when 787        then ForeignKeyViolation.new(full, code.to_s, sql)
      when 1299       then NotNullViolation.new(full, code.to_s, sql)
      else                 QueryError.new(full, code.to_s, sql)
      end
    end
  end
end
