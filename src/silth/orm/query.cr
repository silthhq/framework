module Silth::ORM
  # Typed query over a model. Chainable like `DB::QueryBuilder`, enumerable,
  # with eager loading, scopes and soft-delete awareness.
  #
  # ```
  # Post.where(published: true).includes(:user, :comments).latest.paginate(page)
  # Post.published.search([:title, :body], "crystal").first?
  # Post.nearest(:embedding, embedding).limit(5).to_a
  # ```
  class Query(T) < Silth::DB::QueryBuilder
    include Enumerable(T)

    protected property includes_list : Array(String)
    protected property trashed_mode : Symbol
    protected property defaults : Hash(String, Silth::DB::Value)
    protected property preloaded_records : Array(T)?

    def initialize
      super(T.table_name, T.database)
      @includes_list = [] of String
      @trashed_mode = :without
      @defaults = {} of String => Silth::DB::Value
      @preloaded_records = nil
    end

    protected def spawn : self
      q = super
      q.includes_list = @includes_list.dup
      q.defaults = @defaults.dup
      q.preloaded_records = nil
      q
    end

    # Scopes are chainable on queries: `Post.where(…).published`.
    macro method_missing(call)
      T.__scope_{{call.name.id}}(self{% for a in call.args %}, {{a}}{% end %})
    end

    # :nodoc:
    def __eval_scope(&)
      with self yield
    end

    # :nodoc:
    def __preloaded(records : Array(T)) : self
      q = spawn
      q.preloaded_records = records
      q
    end

    # :nodoc:
    def __with_defaults(values : Hash(String, Silth::DB::Value)) : self
      q = spawn
      q.defaults = @defaults.merge(values)
      q
    end

    def includes(*names : Symbol | String) : self
      spawn.tap { |q| q.includes_list.concat(names.map(&.to_s)) }
    end

    def with_trashed : self
      spawn.tap { |q| q.trashed_mode = :with }
    end

    def only_trashed : self
      spawn.tap { |q| q.trashed_mode = :only }
    end

    # Adds the soft-delete condition on top of the user conditions.
    def compile_wheres : {String, Array(Silth::DB::Value)}
      sql, args = super
      if T.soft_deletes? && @trashed_mode != :with
        column = "#{dialect.quote_table(@table)}.#{dialect.quote("deleted_at")}"
        clause = @trashed_mode == :only ? "#{column} IS NOT NULL" : "#{column} IS NULL"
        sql = sql.empty? ? clause : "(#{sql}) AND #{clause}"
      end
      {sql, args}
    end

    # --- loading -------------------------------------------------------------

    def to_a : Array(T)
      if cached = @preloaded_records
        return cached
      end
      sql, args = to_sql
      result = db.query(sql, args)
      records = result.rows.map { |row| T.from_row(result.columns, row) }
      if !records.empty?
        @includes_list.each { |name| records.first.__preload(records, name) }
      end
      records
    end

    def each(& : T ->)
      to_a.each { |r| yield r }
    end

    def size : Int32
      (cached = @preloaded_records) ? cached.size : count.to_i32
    end

    def empty? : Bool
      (cached = @preloaded_records) ? cached.empty? : !exists?
    end

    def first? : T?
      if cached = @preloaded_records
        return cached.first?
      end
      limit(1).to_a.first?
    end

    def first : T
      first? || raise RecordNotFound.new(T.name)
    end

    def last? : T?
      q = @orders.empty? ? order_by(T.primary_key_name, :desc) : spawn.tap { |s| s.orders = s.orders.map { |(o, a)| {flip(o), a} } }
      q.limit(1).to_a.first?
    end

    def last : T
      last? || raise RecordNotFound.new(T.name)
    end

    private def flip(order : String) : String
      if order.ends_with?(" DESC")
        order.rchop(" DESC") + " ASC"
      elsif order.ends_with?(" ASC")
        order.rchop(" ASC") + " DESC"
      else
        order + " DESC"
      end
    end

    def find?(id) : T?
      where({T.primary_key_name => Silth::DB.to_value(id)}).first?
    end

    def find(id) : T
      find?(id) || raise RecordNotFound.new(T.name, "#{T.primary_key_name}=#{id}")
    end

    def find_by?(**conditions) : T?
      where(**conditions).first?
    end

    def find_by(**conditions) : T
      find_by?(**conditions) || raise RecordNotFound.new(T.name, conditions.to_s)
    end

    def paginate(page : Int = 1, per_page : Int = 20) : Silth::DB::Page(T)
      p = {page.to_i32, 1}.max
      total = count
      Silth::DB::Page(T).new(for_page(p, per_page).to_a, p, per_page.to_i32, total)
    end

    # Keyset pagination on an increasing column (default primary key).
    def cursor_paginate(per_page : Int = 20, cursor : String? = nil, column : String = T.primary_key_name) : Silth::DB::CursorPage(T)
      q = reorder.order_by(column, :asc)
      if cursor
        decoded = String.new(Base64.decode(cursor)) rescue nil
        q = q.where("#{dialect.quote_column(column)} > ?", decoded.try(&.to_i64?) || decoded) if decoded
      end
      records = q.limit(per_page + 1).to_a
      next_cursor = nil
      if records.size > per_page
        records = records.first(per_page)
        next_cursor = Base64.urlsafe_encode(records.last.read_attribute(column).to_s, padding: false)
      end
      Silth::DB::CursorPage(T).new(records, next_cursor)
    end

    def find_each(size : Int32 = 1000, & : T ->) : Nil
      last_id = nil
      pk = T.primary_key_name
      loop do
        q = reorder.order_by(pk, :asc).limit(size)
        q = q.where("#{dialect.quote_column(pk)} > ?", last_id) if last_id
        batch = q.to_a
        break if batch.empty?
        batch.each { |r| yield r }
        break if batch.size < size
        last_id = batch.last.read_attribute(pk)
      end
    end

    # --- building ---------------------------------------------------------------

    def build(**attrs) : T
      record = T.new
      @defaults.each { |k, v| record.write_attribute(k, v) }
      record.assign(**attrs)
      record
    end

    def create(**attrs) : T
      record = build(**attrs)
      record.save
      record
    end

    def create!(**attrs) : T
      build(**attrs).save!
    end

    def first_or_new(**attrs) : T
      where(**attrs).first? || build(**attrs)
    end

    def first_or_create(**attrs) : T
      where(**attrs).first? || create!(**attrs)
    end

    # --- bulk ---------------------------------------------------------------

    def update_all(**values) : Int64
      update(**values)
    end

    def delete_all : Int64
      delete
    end

    def destroy_all : Int32
      records = to_a
      records.each(&.destroy)
      records.size
    end
  end
end
