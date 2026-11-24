module Silth::DB
  # Pagination metadata shared by every paginated result.
  module PageInfo
    abstract def page : Int32
    abstract def per_page : Int32
    abstract def total : Int64

    def total_pages : Int32
      per_page <= 0 ? 1 : {((total + per_page - 1) // per_page).to_i32, 1}.max
    end

    def next_page : Int32?
      page < total_pages ? page + 1 : nil
    end

    def prev_page : Int32?
      page > 1 ? page - 1 : nil
    end

    def first_page? : Bool
      page == 1
    end

    def last_page? : Bool
      page >= total_pages
    end

    def from : Int64
      total == 0 ? 0_i64 : ((page - 1) * per_page + 1).to_i64
    end

    def to : Int64
      {from + per_page - 1, total}.min
    end
  end

  # A page of records (`Post.paginate(2)`, `DB.table("x").paginate(1, 50)`).
  class Page(T)
    include PageInfo
    include Enumerable(T)

    getter items : Array(T)
    getter page : Int32
    getter per_page : Int32
    getter total : Int64

    def initialize(@items : Array(T), @page : Int32, @per_page : Int32, @total : Int64)
    end

    def each(& : T ->)
      @items.each { |i| yield i }
    end

    def empty? : Bool
      @items.empty?
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "data", @items
        json.field "meta" do
          json.object do
            json.field "page", page
            json.field "per_page", per_page
            json.field "total", total
            json.field "total_pages", total_pages
          end
        end
      end
    end
  end

  # Keyset (cursor) pagination result — stable and fast on large tables.
  class CursorPage(T)
    include Enumerable(T)

    getter items : Array(T)
    getter next_cursor : String?

    def initialize(@items : Array(T), @next_cursor : String?)
    end

    def each(& : T ->)
      @items.each { |i| yield i }
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "data", @items
        json.field "next_cursor", @next_cursor
      end
    end
  end

  # Fluent, dialect aware SQL builder. Every method returns a new builder.
  #
  # ```
  # DB.table("posts")
  #   .where(published: true)
  #   .where(:views, ">", 100)
  #   .where("title LIKE ?", "%crystal%")
  #   .order(created_at: :desc)
  #   .limit(10)
  #   .rows
  # ```
  class QueryBuilder
    OPERATORS = Set{"=", "!=", "<>", "<", ">", "<=", ">=", "LIKE", "NOT LIKE", "ILIKE", "NOT ILIKE", "IN", "NOT IN",
                    "@>", "<@", "&&", "~", "~*", "IS", "IS NOT", "REGEXP"}

    getter db : Database
    getter table : String
    protected property selects : Array(String)
    protected property wheres : Array({String, String, Array(Value)})
    protected property joins : Array({String, Array(Value)})
    protected property orders : Array({String, Array(Value)})
    protected property groups : Array(String)
    protected property havings : Array({String, Array(Value)})
    protected property ctes : Array({String, String, Array(Value)})
    protected property limit_value : Int32?
    protected property offset_value : Int32?
    protected property distinct_value : Bool
    protected property lock_value : String?
    protected property from_alias : String?

    # Note: ivars are initialized here (not inline) so generic subclasses such as
    # `ORM::Query(T)` can reuse them.
    def initialize(@table : String, @db : Database = DB.connection)
      @selects = [] of String
      @wheres = [] of {String, String, Array(Value)}
      @joins = [] of {String, Array(Value)}
      @orders = [] of {String, Array(Value)}
      @groups = [] of String
      @havings = [] of {String, Array(Value)}
      @ctes = [] of {String, String, Array(Value)}
      @limit_value = nil
      @offset_value = nil
      @distinct_value = false
      @lock_value = nil
      @from_alias = nil
    end

    def dialect : Dialect
      @db.dialect
    end

    protected def spawn : self
      q = dup
      q.selects = @selects.dup
      q.wheres = @wheres.dup
      q.joins = @joins.dup
      q.orders = @orders.dup
      q.groups = @groups.dup
      q.havings = @havings.dup
      q.ctes = @ctes.dup
      q
    end

    private def q(column : String | Symbol) : String
      dialect.quote_column(column.to_s)
    end

    # --- select --------------------------------------------------------------

    def select(*columns : String | Symbol) : self
      spawn.tap { |s| s.selects.concat(columns.map { |c| q(c) }) }
    end

    def select_raw(sql : String) : self
      spawn.tap { |s| s.selects << sql }
    end

    def distinct : self
      spawn.tap { |s| s.distinct_value = true }
    end

    # --- where ---------------------------------------------------------------

    def where(**conditions) : self
      s = spawn
      conditions.each { |k, v| s.add_condition("AND", k.to_s, v) }
      s
    end

    def where(conditions : Hash) : self
      s = spawn
      conditions.each { |k, v| s.add_condition("AND", k.to_s, v) }
      s
    end

    # `where(:views, ">", 10)` — the column is a Symbol.
    def where(column : Symbol, operator : String, value) : self
      spawn.tap { |s| s.add_operator("AND", column.to_s, operator, value) }
    end

    # `where("lower(email) = ?", email)` — raw SQL fragment with `?` placeholders.
    def where(sql : String, *args) : self
      spawn.tap { |s| s.wheres << {"AND", sql, DB.values(args)} }
    end

    def or_where(**conditions) : self
      s = spawn
      conditions.each { |k, v| s.add_condition("OR", k.to_s, v) }
      s
    end

    def or_where(column : Symbol, operator : String, value) : self
      spawn.tap { |s| s.add_operator("OR", column.to_s, operator, value) }
    end

    def or_where(sql : String, *args) : self
      spawn.tap { |s| s.wheres << {"OR", sql, DB.values(args)} }
    end

    def where_not(**conditions) : self
      s = spawn
      conditions.each do |k, v|
        case v
        when Nil   then s.wheres << {"AND", "#{q(k.to_s)} IS NOT NULL", [] of Value}
        when Array then s.add_in("AND", k.to_s, v, true)
        else            s.wheres << {"AND", "#{q(k.to_s)} <> ?", [DB.to_value(v)] of Value}
        end
      end
      s
    end

    def where_in(column : String | Symbol, values : Enumerable) : self
      spawn.tap { |s| s.add_in("AND", column.to_s, values.to_a, false) }
    end

    def where_in(column : String | Symbol, subquery : QueryBuilder) : self
      sql, args = subquery.to_sql
      spawn.tap { |s| s.wheres << {"AND", "#{q(column)} IN (#{sql})", args} }
    end

    def where_not_in(column : String | Symbol, values : Enumerable) : self
      spawn.tap { |s| s.add_in("AND", column.to_s, values.to_a, true) }
    end

    def where_null(column : String | Symbol) : self
      spawn.tap { |s| s.wheres << {"AND", "#{q(column)} IS NULL", [] of Value} }
    end

    def where_not_null(column : String | Symbol) : self
      spawn.tap { |s| s.wheres << {"AND", "#{q(column)} IS NOT NULL", [] of Value} }
    end

    def where_between(column : String | Symbol, from, to) : self
      spawn.tap { |s| s.wheres << {"AND", "#{q(column)} BETWEEN ? AND ?", [DB.to_value(from), DB.to_value(to)] of Value} }
    end

    def where_like(column : String | Symbol, pattern : String, case_sensitive : Bool = false) : self
      sql = case_sensitive ? "#{q(column)} LIKE ?" : dialect.case_insensitive_like(column.to_s)
      spawn.tap { |s| s.wheres << {"AND", sql, [pattern.as(Value)]} }
    end

    def where_exists(subquery : QueryBuilder) : self
      sql, args = subquery.to_sql
      spawn.tap { |s| s.wheres << {"AND", "EXISTS (#{sql})", args} }
    end

    # Groups conditions in parentheses: `where_group { |g| g.where(a: 1).or_where(b: 2) }`.
    def where_group(conjunction : String = "AND", & : QueryBuilder -> QueryBuilder) : self
      group = yield QueryBuilder.new(@table, @db)
      sql, args = group.compile_wheres
      return self if sql.empty?
      spawn.tap { |s| s.wheres << {conjunction, "(#{sql})", args} }
    end

    def or_where_group(& : QueryBuilder -> QueryBuilder) : self
      where_group("OR") { |g| yield g }
    end

    # JSON path equality: `where_json(:settings, "theme.color", "dark")`.
    def where_json(column : String | Symbol, path : String, value) : self
      spawn.tap { |s| s.wheres << {"AND", "#{dialect.json_extract(column.to_s, path)} = ?", [DB.to_value(value).to_s.as(Value)]} }
    end

    # JSON containment (`@>` on PostgreSQL, `JSON_CONTAINS` on MySQL).
    def where_json_contains(column : String | Symbol, value) : self
      json = value.to_json
      sql = case dialect.name
            when "postgres" then "#{q(column)} @> ?::jsonb"
            when "mysql"    then "JSON_CONTAINS(#{q(column)}, ?)"
            else                 raise Unsupported.new("where_json_contains is not supported on SQLite")
            end
      spawn.tap { |s| s.wheres << {"AND", sql, [json.as(Value)]} }
    end

    # Full-text search across columns.
    # PostgreSQL: `to_tsvector @@ websearch_to_tsquery`, MySQL: `MATCH … AGAINST`, SQLite: LIKE fallback.
    # Pass `vector:` to use a stored tsvector column.
    def search(columns : Array(String | Symbol) | String | Symbol, query : String, language : String = "english", vector : String | Symbol | Nil = nil) : self
      cols = columns.is_a?(Array) ? columns.map(&.to_s) : [columns.to_s]
      case dialect.name
      when "postgres"
        doc = vector ? q(vector) : tsvector_expr(cols, language)
        spawn.tap { |s| s.wheres << {"AND", "#{doc} @@ websearch_to_tsquery('#{language.gsub("'", "")}', ?)", [query.as(Value)]} }
      when "mysql"
        spawn.tap { |s| s.wheres << {"AND", "MATCH(#{cols.map { |c| q(c) }.join(", ")}) AGAINST (? IN NATURAL LANGUAGE MODE)", [query.as(Value)]} }
      else
        terms = query.split(/\s+/).reject(&.empty?)
        s = spawn
        terms.each do |term|
          clause = cols.map { |c| "#{q(c)} LIKE ?" }.join(" OR ")
          s.wheres << {"AND", "(#{clause})", Array(Value).new(cols.size) { "%#{term}%".as(Value) }}
        end
        s
      end
    end

    # Orders by full-text relevance (PostgreSQL `ts_rank`, MySQL `MATCH` score).
    def order_by_relevance(columns : Array(String | Symbol) | String | Symbol, query : String, language : String = "english", vector : String | Symbol | Nil = nil) : self
      cols = columns.is_a?(Array) ? columns.map(&.to_s) : [columns.to_s]
      case dialect.name
      when "postgres"
        doc = vector ? q(vector) : tsvector_expr(cols, language)
        spawn.tap { |s| s.orders << {"ts_rank(#{doc}, websearch_to_tsquery('#{language.gsub("'", "")}', ?)) DESC", [query.as(Value)]} }
      when "mysql"
        spawn.tap { |s| s.orders << {"MATCH(#{cols.map { |c| q(c) }.join(", ")}) AGAINST (?) DESC", [query.as(Value)]} }
      else
        self
      end
    end

    private def tsvector_expr(cols : Array(String), language : String) : String
      "to_tsvector('#{language.gsub("'", "")}', #{cols.map { |c| "coalesce(#{q(c)}::text, '')" }.join(" || ' ' || ")})"
    end

    # Vector similarity search with pgvector: `nearest(:embedding, vec, metric: :cosine).limit(5)`.
    def nearest(column : String | Symbol, vector : Array(Float32), metric : Symbol = :cosine) : self
      raise Unsupported.new("Vector search requires PostgreSQL with the pgvector extension") unless dialect.name == "postgres"
      op = vector_operator(metric)
      spawn.tap { |s| s.orders << {"#{q(column)} #{op} ?", [vector.as(Value)]} }
    end

    # Adds the distance as a selected column (alias `distance` by default).
    def select_distance(column : String | Symbol, vector : Array(Float32), metric : Symbol = :cosine, as name : String = "distance") : self
      raise Unsupported.new("Vector search requires PostgreSQL with the pgvector extension") unless dialect.name == "postgres"
      s = spawn
      s.selects << "#{dialect.quote_table(@table)}.*" if s.selects.empty?
      s.selects << "(#{q(column)} #{vector_operator(metric)} '[#{vector.join(',')}]') AS #{dialect.quote(name)}"
      s
    end

    def where_distance(column : String | Symbol, vector : Array(Float32), max : Float64, metric : Symbol = :cosine) : self
      raise Unsupported.new("Vector search requires PostgreSQL with the pgvector extension") unless dialect.name == "postgres"
      spawn.tap { |s| s.wheres << {"AND", "#{q(column)} #{vector_operator(metric)} ? < ?", [vector.as(Value), max.as(Value)]} }
    end

    private def vector_operator(metric : Symbol) : String
      case metric
      when :l2, :euclidean then "<->"
      when :inner_product  then "<#>"
      when :l1, :manhattan then "<+>"
      else                      "<=>"
      end
    end

    protected def add_condition(conj : String, column : String, value) : Nil
      case value
      when Nil   then @wheres << {conj, "#{q(column)} IS NULL", [] of Value}
      when Array then add_in(conj, column, value, false)
      when Range
        @wheres << {conj, "#{q(column)} BETWEEN ? AND ?", [DB.to_value(value.begin), DB.to_value(value.end)] of Value}
      else
        @wheres << {conj, "#{q(column)} = ?", [DB.to_value(value)] of Value}
      end
    end

    protected def add_operator(conj : String, column : String, operator : String, value) : Nil
      op = operator.upcase
      raise Error.new("Unsupported operator '#{operator}'") unless OPERATORS.includes?(op)
      if value.is_a?(Array) && (op == "IN" || op == "NOT IN")
        add_in(conj, column, value, op == "NOT IN")
      elsif value.nil?
        @wheres << {conj, "#{q(column)} #{op == "!=" || op == "<>" || op == "IS NOT" ? "IS NOT" : "IS"} NULL", [] of Value}
      else
        @wheres << {conj, "#{q(column)} #{op} ?", [DB.to_value(value)] of Value}
      end
    end

    protected def add_in(conj : String, column : String, values : Array, negate : Bool) : Nil
      if values.empty?
        @wheres << {conj, negate ? "1 = 1" : "1 = 0", [] of Value}
      else
        @wheres << {conj, "#{q(column)} #{negate ? "NOT IN" : "IN"} (#{(["?"] * values.size).join(", ")})", DB.values(values)}
      end
    end

    # --- joins / ordering / grouping ------------------------------------------

    def join(table : String, on : String, *args) : self
      spawn.tap { |s| s.joins << {"INNER JOIN #{dialect.quote_table(table)} ON #{on}", DB.values(args)} }
    end

    def left_join(table : String, on : String, *args) : self
      spawn.tap { |s| s.joins << {"LEFT JOIN #{dialect.quote_table(table)} ON #{on}", DB.values(args)} }
    end

    def join_raw(sql : String, *args) : self
      spawn.tap { |s| s.joins << {sql, DB.values(args)} }
    end

    def order(**columns) : self
      s = spawn
      columns.each do |col, dir|
        direction = dir.to_s.downcase
        raise Error.new("Invalid order direction '#{dir}'") unless direction.in?("asc", "desc", "asc nulls last", "desc nulls last", "asc nulls first", "desc nulls first")
        s.orders << {"#{q(col.to_s)} #{direction.upcase}", [] of Value}
      end
      s
    end

    def order(sql : String, *args) : self
      spawn.tap { |s| s.orders << {sql, DB.values(args)} }
    end

    def order_by(column : String | Symbol, direction : Symbol | String = :asc) : self
      dir = direction.to_s.downcase == "desc" ? "DESC" : "ASC"
      spawn.tap { |s| s.orders << {"#{q(column)} #{dir}", [] of Value} }
    end

    def latest(column : String | Symbol = "created_at") : self
      order_by(column, :desc)
    end

    def oldest(column : String | Symbol = "created_at") : self
      order_by(column, :asc)
    end

    def reorder : self
      spawn.tap { |s| s.orders.clear }
    end

    def in_random_order : self
      spawn.tap { |s| s.orders << {dialect.random_sql, [] of Value} }
    end

    def group_by(*columns : String | Symbol) : self
      spawn.tap { |s| s.groups.concat(columns.map { |c| q(c) }) }
    end

    def having(sql : String, *args) : self
      spawn.tap { |s| s.havings << {sql, DB.values(args)} }
    end

    def limit(n : Int) : self
      spawn.tap { |s| s.limit_value = n.to_i32 }
    end

    def offset(n : Int) : self
      spawn.tap { |s| s.offset_value = n.to_i32 }
    end

    def take(n : Int) : self
      limit(n)
    end

    def for_page(page : Int, per_page : Int) : self
      p = {page.to_i32, 1}.max
      limit(per_page).offset((p - 1) * per_page)
    end

    # `SELECT … FOR UPDATE [SKIP LOCKED]` (PostgreSQL/MySQL; ignored on SQLite).
    def lock_for_update(skip_locked : Bool = false, nowait : Bool = false) : self
      return self if dialect.name == "sqlite"
      clause = "FOR UPDATE"
      clause += " SKIP LOCKED" if skip_locked && dialect.supports_skip_locked?
      clause += " NOWAIT" if nowait
      spawn.tap { |s| s.lock_value = clause }
    end

    def shared_lock : self
      return self if dialect.name == "sqlite"
      spawn.tap { |s| s.lock_value = dialect.name == "mysql" ? "LOCK IN SHARE MODE" : "FOR SHARE" }
    end

    # Common table expression: `with_cte("recent", "SELECT * FROM posts WHERE …")`.
    def with_cte(name : String, sql : String, *args) : self
      spawn.tap { |s| s.ctes << {name, sql, DB.values(args)} }
    end

    def with_cte(name : String, query : QueryBuilder) : self
      sql, args = query.to_sql
      spawn.tap { |s| s.ctes << {name, sql, args} }
    end

    def from(alias_name : String) : self
      spawn.tap { |s| s.from_alias = alias_name }
    end

    # --- SQL compilation -------------------------------------------------------

    def compile_wheres : {String, Array(Value)}
      args = [] of Value
      sql = String.build do |io|
        @wheres.each_with_index do |(conj, fragment, fargs), i|
          io << ' ' << conj << ' ' unless i == 0
          io << fragment
          args.concat(fargs)
        end
      end
      {sql, args}
    end

    def to_sql(select_override : String? = nil) : {String, Array(Value)}
      args = [] of Value
      sql = String.build do |io|
        unless @ctes.empty?
          io << "WITH "
          @ctes.each_with_index do |(name, cte_sql, cte_args), i|
            io << ", " unless i == 0
            io << dialect.quote(name) << " AS (" << cte_sql << ')'
            args.concat(cte_args)
          end
          io << ' '
        end
        io << "SELECT "
        io << "DISTINCT " if @distinct_value
        io << (select_override || (@selects.empty? ? "#{dialect.quote_table(@table)}.*" : @selects.join(", ")))
        io << " FROM " << dialect.quote_table(@table)
        io << ' ' << dialect.quote(@from_alias.not_nil!) if @from_alias
        @joins.each do |(join_sql, join_args)|
          io << ' ' << join_sql
          args.concat(join_args)
        end
        where_sql, where_args = compile_wheres
        unless where_sql.empty?
          io << " WHERE " << where_sql
          args.concat(where_args)
        end
        io << " GROUP BY " << @groups.join(", ") unless @groups.empty?
        unless @havings.empty?
          io << " HAVING " << @havings.map(&.[0]).join(" AND ")
          @havings.each { |h| args.concat(h[1]) }
        end
        if select_override.nil? || !select_override.starts_with?("COUNT")
          unless @orders.empty?
            io << " ORDER BY " << @orders.map(&.[0]).join(", ")
            @orders.each { |o| args.concat(o[1]) }
          end
          if l = @limit_value
            io << " LIMIT " << l
          elsif @offset_value && dialect.name != "postgres"
            io << " LIMIT " << (dialect.name == "mysql" ? "18446744073709551615" : "-1")
          end
          io << " OFFSET " << @offset_value if @offset_value
          io << ' ' << @lock_value if @lock_value
        end
      end
      {sql, args}
    end

    def to_s(io : IO) : Nil
      io << to_sql[0]
    end

    # --- execution --------------------------------------------------------------

    def rows : Array(Row)
      sql, args = to_sql
      @db.query(sql, args).to_hashes
    end

    def first? : Row?
      limit(1).rows.first?
    end

    def first : Row
      first? || raise Error.new("No rows found in #{@table}")
    end

    def count(column : String = "*") : Int64
      base = spawn
      base.orders = [] of {String, Array(Value)}
      if !@groups.empty? || @distinct_value
        inner_sql, args = base.to_sql
        value = @db.scalar("SELECT COUNT(*) FROM (#{inner_sql}) silth_count", args)
      else
        sql, args = base.to_sql("COUNT(#{column == "*" ? "*" : q(column)})")
        value = @db.scalar(sql, args)
      end
      DB.as_i64(value)
    end

    def exists? : Bool
      sql, args = limit(1).to_sql("1")
      !@db.query(sql, args).empty?
    end

    def pluck(column : String | Symbol) : Array(Value)
      sql, args = to_sql(q(column))
      @db.query(sql, args).rows.map(&.first)
    end

    {% for fn in %w(sum avg min max) %}
      def {{fn.id}}(column : String | Symbol) : Float64?
        sql, args = reorder.to_sql("{{fn.upcase.id}}(#{q(column)})")
        value = @db.scalar(sql, args)
        DB.as_f64?(value)
      end
    {% end %}

    def paginate(page : Int = 1, per_page : Int = 20) : Page(Row)
      p = {page.to_i32, 1}.max
      Page(Row).new(for_page(p, per_page).rows, p, per_page.to_i32, count)
    end

    def each_batch(size : Int32 = 1000, & : Array(Row) ->) : Nil
      offset = 0
      loop do
        batch = limit(size).offset(offset).rows
        break if batch.empty?
        yield batch
        break if batch.size < size
        offset += size
      end
    end

    # --- writes -----------------------------------------------------------------

    # Inserts a row and returns the generated id (when available).
    def insert(**values) : Int64?
      hash = {} of String => Value
      values.each { |k, v| hash[k.to_s] = DB.to_value(v) }
      insert(hash)
    end

    def insert(values : Hash(String, Value), returning : String? = "id") : Int64?
      return nil if values.empty?
      cols = values.keys.map { |c| dialect.quote(c) }.join(", ")
      placeholders = (["?"] * values.size).join(", ")
      sql = "INSERT INTO #{dialect.quote_table(@table)} (#{cols}) VALUES (#{placeholders})"
      if returning && dialect.supports_returning?
        sql += " RETURNING #{dialect.quote(returning)}"
        result = @db.query(sql, values.values)
        DB.as_i64?(result.scalar)
      else
        result = @db.query(sql, values.values)
        result.last_insert_id
      end
    end

    def insert_all(rows : Array(Hash(String, Value))) : Int64
      return 0_i64 if rows.empty?
      columns = rows.first.keys
      args = [] of Value
      values_sql = rows.map do |row|
        columns.each { |c| args << row[c]? }
        "(#{(["?"] * columns.size).join(", ")})"
      end.join(", ")
      @db.query("INSERT INTO #{dialect.quote_table(@table)} (#{columns.map { |c| dialect.quote(c) }.join(", ")}) VALUES #{values_sql}", args).rows_affected
    end

    # Insert or update on conflict (`ON CONFLICT … DO UPDATE` / `ON DUPLICATE KEY UPDATE`).
    def upsert(rows : Array(Hash(String, Value)), conflict : Array(String), update : Array(String)? = nil) : Int64
      return 0_i64 if rows.empty?
      columns = rows.first.keys
      updates = update || (columns - conflict)
      args = [] of Value
      values_sql = rows.map do |row|
        columns.each { |c| args << row[c]? }
        "(#{(["?"] * columns.size).join(", ")})"
      end.join(", ")
      @db.query(dialect.upsert_sql(@table, columns, values_sql, conflict, updates), args).rows_affected
    end

    def update(**values) : Int64
      hash = {} of String => Value
      values.each { |k, v| hash[k.to_s] = DB.to_value(v) }
      update(hash)
    end

    def update(values : Hash(String, Value)) : Int64
      return 0_i64 if values.empty?
      set = values.keys.map { |c| "#{dialect.quote(c)} = ?" }.join(", ")
      where_sql, where_args = compile_wheres
      sql = "UPDATE #{dialect.quote_table(@table)} SET #{set}"
      sql += " WHERE #{where_sql}" unless where_sql.empty?
      @db.query(sql, values.values + where_args).rows_affected
    end

    def increment(column : String | Symbol, by : Int = 1) : Int64
      where_sql, where_args = compile_wheres
      sql = "UPDATE #{dialect.quote_table(@table)} SET #{q(column)} = #{q(column)} + ?"
      sql += " WHERE #{where_sql}" unless where_sql.empty?
      @db.query(sql, [by.to_i64.as(Value)] + where_args).rows_affected
    end

    def decrement(column : String | Symbol, by : Int = 1) : Int64
      increment(column, -by)
    end

    def delete : Int64
      where_sql, where_args = compile_wheres
      sql = "DELETE FROM #{dialect.quote_table(@table)}"
      sql += " WHERE #{where_sql}" unless where_sql.empty?
      @db.query(sql, where_args).rows_affected
    end

    def explain : String
      sql, args = to_sql
      @db.query("EXPLAIN #{sql}", args).rows.map { |r| r.compact_map(&.to_s).join(" ") }.join('\n')
    end
  end

  def self.values(args) : Array(Value)
    result = [] of Value
    args.each { |a| result << to_value(a) }
    result
  end

  def self.as_i64(value : Value) : Int64
    as_i64?(value) || 0_i64
  end

  def self.as_i64?(value : Value) : Int64?
    case value
    when Int32, Int64 then value.to_i64
    when Float32, Float64 then value.to_i64
    when String then value.to_i64?
    when Bool then value ? 1_i64 : 0_i64
    else nil
    end
  end

  def self.as_f64?(value : Value) : Float64?
    case value
    when Int32, Int64, Float32, Float64 then value.to_f64
    when String then value.to_f64?
    else nil
    end
  end
end
