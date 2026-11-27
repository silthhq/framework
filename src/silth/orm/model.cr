module Silth
  module ORM
    class RecordNotFound < Silth::Error
      def initialize(model : String, detail : String = "")
        super("#{model} not found#{detail.empty? ? "" : " (#{detail})"}")
      end
    end

    class RecordInvalid < Silth::Error
      getter errors : Validation::Errors

      def initialize(model : String, @errors : Validation::Errors)
        super("#{model} is invalid: #{@errors.full_messages.join(", ")}")
      end
    end

    # Raised when an optimistically locked record changed in the database since it was read.
    class StaleObjectError < Silth::Error
      def initialize(model : String, id : DB::Value, version : Int64)
        super("#{model} #{id} was changed by someone else (#{model}##{id} is no longer at lock_version #{version}): reload it and try again")
      end
    end

    class MissingAttribute < Silth::Error
      def initialize(model : String, attribute : String)
        super("#{model}##{attribute} is nil (not loaded or not set). Use `#{attribute}?` for a nilable read.")
      end
    end
  end

  # Active Record style models.
  #
  # ```
  # class Post < Silth::Model
  #   primary_key
  #   column title : String
  #   column body : String?
  #   column published : Bool = false
  #   column embedding : Array(Float32)? # pgvector
  #   timestamps
  #
  #   belongs_to user : User
  #   has_many comments : Comment, dependent: :destroy
  #
  #   validates title, presence: true, length: {min: 3, max: 120}
  #   scope published { where(published: true) }
  #
  #   def before_save
  #     self.title = title.strip
  #   end
  # end
  #
  # post = Post.create!(title: "Hello", user_id: 1)
  # Post.published.order(created_at: :desc).limit(10).each { |p| puts p.title }
  # ```
  abstract class Model
    annotation Column
    end

    @__persisted = false
    @__destroyed = false
    @__changes : Hash(String, {DB::Value, DB::Value})? = nil
    @__extra : Hash(String, DB::Value)? = nil
    @__errors : Validation::Errors? = nil

    def self.soft_deletes? : Bool
      false
    end

    def self.connection_name : String?
      nil
    end

    macro inherited
      def self.table_name : String
        ::Silth::Inflector.tableize({{@type.name.stringify}})
      end

      def self.query : ::Silth::ORM::Query({{@type}})
        ::Silth::ORM::Query({{@type}}).new
      end

      def self.database : ::Silth::DB::Database
        ::Silth::DB.connection(connection_name)
      end

      {% for m in %w(where or_where where_not where_in where_not_in where_null where_not_null where_between where_like
                    where_json where_json_contains search order_by_relevance nearest select_distance where_distance
                    join left_join order order_by latest oldest limit offset includes group_by having distinct
                    with_trashed only_trashed lock_for_update select select_raw for_page take in_random_order
                    where_exists find find? find_by find_by? first first? last last? count exists? pluck sum avg min max
                    paginate cursor_paginate to_a create create! first_or_create first_or_new
                    update_all delete_all destroy_all) %}
        def self.{{m.id}}(*args, **opts)
          query.{{m.id}}(*args, **opts)
        end
      {% end %}

      def self.all : Array({{@type}})
        query.to_a
      end

      def self.where_group(& : ::Silth::DB::QueryBuilder -> ::Silth::DB::QueryBuilder) : ::Silth::ORM::Query({{@type}})
        query.where_group { |g| yield g }
      end

      def self.find_each(size : Int32 = 1000, & : {{@type}} ->) : Nil
        query.find_each(size) { |r| yield r }
      end

      def self.transaction(&)
        database.transaction { yield }
      end

      # Builds records from raw SQL: `Post.find_by_sql("SELECT * FROM posts WHERE …", [1])`.
      def self.find_by_sql(sql : String, args : Enumerable = [] of ::Silth::DB::Value) : Array({{@type}})
        result = database.query(sql, args)
        result.rows.map { |row| from_row(result.columns, row) }
      end

      def self.from_row(columns : Array(String), row : Array(::Silth::DB::Value)) : {{@type}}
        instance = new
        instance.__load_row(columns, row)
        instance.__mark_persisted
        instance
      end

      def self.insert_all(rows : Array(Hash(String, ::Silth::DB::Value))) : Int64
        ::Silth::DB::QueryBuilder.new(table_name, database).insert_all(rows)
      end

      def self.upsert(rows : Array(Hash(String, ::Silth::DB::Value)), conflict : Array(String), update : Array(String)? = nil) : Int64
        ::Silth::DB::QueryBuilder.new(table_name, database).upsert(rows, conflict, update)
      end
    end

    # --- declarations --------------------------------------------------------

    macro table(name)
      def self.table_name : String
        {{name.id.stringify}}
      end
    end

    macro connection(name)
      def self.connection_name : String?
        {{name.id.stringify}}
      end
    end

    # Declares a column: `column title : String`, `column views : Int32 = 0`.
    # Options: `hidden: true` (excluded from JSON), `column: "db_name"`,
    # `uuid: true` (a UUIDv7 set on insert when empty, `uuid: :v4` for a random one).
    macro column(decl, primary = false, auto = false, hidden = false, column = nil, uuid = false)
      {% type = decl.type.resolve %}
      {% nilable = type.nilable? %}
      {% base = type.union? ? type.union_types.reject(&.nilable?).first : type %}
      {% name = decl.var %}
      @[::Silth::Model::Column(type: {{base}}, nilable: {{nilable}}, primary: {{primary}}, auto: {{auto}}, hidden: {{hidden}}, uuid: {{uuid}}, name: {{(column || name).id.stringify}})]
      @{{name}} : {{base}}? = {% if decl.value.is_a?(Nop) %}nil{% else %}{{decl.value}}{% end %}

      def {{name}} : {{nilable ? type : base}}
        {% if nilable %}
          @{{name}}
        {% else %}
          %v = @{{name}}
          raise ::Silth::ORM::MissingAttribute.new({{@type.name.stringify}}, {{name.stringify}}) if %v.nil?
          %v
        {% end %}
      end

      def {{name}}=(value : {{base}}?)
        __track_change({{(column || name).id.stringify}}, ::Silth::ORM::Cast.to_db(@{{name}}), ::Silth::ORM::Cast.to_db(value))
        @{{name}} = value
      end

      {% if base.stringify == "Bool" %}
        def {{name}}? : Bool
          @{{name}} == true
        end
      {% else %}
        def {{name}}? : {{base}}?
          @{{name}}
        end
      {% end %}
    end

    # `primary_key` (BIGINT auto increment `id`) or `primary_key id : String, uuid: true` (UUIDv7).
    macro primary_key(decl = nil, uuid = false)
      {% if decl == nil %}
        column id : Int64, primary: true, auto: true
      {% else %}
        column {{decl}}, primary: true, auto: {{!uuid && decl.type.resolve.union_types.any? { |t| t.stringify.starts_with?("Int") }}}, uuid: {{uuid}}
      {% end %}

      def to_param : String
        @{{decl ? decl.var : "id".id}}.to_s
      end

      def self.primary_key_name : String
        {{(decl ? decl.var : "id").id.stringify}}
      end
    end

    macro timestamps
      column created_at : Time?
      column updated_at : Time?
    end

    # Soft deletion: `destroy` sets `deleted_at`, queries hide trashed rows.
    macro soft_deletes
      column deleted_at : Time?

      def self.soft_deletes? : Bool
        true
      end

      def trashed? : Bool
        !@deleted_at.nil?
      end

      def restore : Bool
        self.deleted_at = nil
        save
      end

      def force_destroy : Bool
        __delete_row
        @__destroyed = true
        true
      end
    end

    # Optimistic locking: every update or destroy checks that `lock_version` (an
    # integer column, `t.lock_version` in migrations) still holds the value read with
    # the record, and increments it. A concurrent change raises `ORM::StaleObjectError`.
    #
    # ```
    # class Order < Silth::Model
    #   primary_key
    #   column total : Float64
    #   optimistic_locking
    # end
    # ```
    macro optimistic_locking(column = lock_version)
      column {{column.id}} : Int32 = 0

      def self.locking_column : String?
        {{column.id.stringify}}
      end
    end

    def self.locking_column : String?
      nil
    end

    # Reusable query: `scope published { where(published: true) }`, also chainable on queries.
    macro scope(name, &block)
      {% blk = block.is_a?(Nop) ? name.block : block %}
      {% sname = name.is_a?(Call) ? name.name : name.id %}
      def self.__scope_{{sname}}(__query : ::Silth::ORM::Query({{@type}}){% for a in blk.args %}, {{a.id}}{% end %}) : ::Silth::ORM::Query({{@type}})
        __query.__eval_scope do
          {{blk.body}}
        end
      end

      def self.{{sname}}({{blk.args.splat}}) : ::Silth::ORM::Query({{@type}})
        __scope_{{sname}}(query{% for a in blk.args %}, {{a.id}}{% end %})
      end
    end

    # --- associations ----------------------------------------------------------

    # `belongs_to user : User` declares `user_id : Int64` and a lazy `user` reader.
    #
    # ```
    # belongs_to post : Post, counter_cache: true              # keeps posts.comments_count up to date
    # belongs_to commentable, polymorphic: true                # commentable_type + commentable_id, returns Silth::Model?
    # belongs_to commentable : Post | Video, polymorphic: true # only these classes (still Silth::Model?)
    # belongs_to imageable : User, polymorphic: true           # one class: the reader returns User?
    # ```
    macro belongs_to(decl, foreign_key = nil, optional = false, primary_key = "id", polymorphic = false, counter_cache = nil)
      {% if polymorphic %}
        {% raise "counter_cache is not supported on polymorphic belongs_to" if counter_cache %}
        __polymorphic_belongs_to({{decl}}, {{optional}})
      {% else %}
        __belongs_to({{decl}}, {{foreign_key}}, {{optional}}, {{primary_key}}, {{counter_cache}})
      {% end %}
    end

    # :nodoc:
    macro __belongs_to(decl, foreign_key, optional, primary_key, counter_cache)
      {% name = decl.var %}
      {% klass = decl.type %}
      {% fk = (foreign_key || "#{name}_id").id %}
      {% unless @type.has_method?(fk.stringify) %}
        column {{fk}} : Int64{% if optional %}?{% end %}
      {% end %}
      @__rel_{{name}} : {{klass}}? = nil
      @__rel_{{name}}_loaded = false

      def {{name}} : {{klass}}?
        return @__rel_{{name}} if @__rel_{{name}}_loaded
        @__rel_{{name}}_loaded = true
        @__rel_{{name}} = (%key = @{{fk}}) ? {{klass}}.find_by?({{primary_key.id}}: %key) : nil
      end

      def {{name}}! : {{klass}}
        {{name}} || raise ::Silth::ORM::RecordNotFound.new({{klass.stringify}}, "{{fk}}=#{@{{fk}}}")
      end

      def {{name}}=(record : {{klass}}?) : Nil
        @__rel_{{name}} = record
        @__rel_{{name}}_loaded = true
        self.{{fk}} = record.try(&.{{primary_key.id}}?)
      end

      # :nodoc:
      def __set_{{name}}(record : {{klass}}?) : Nil
        @__rel_{{name}} = record
        @__rel_{{name}}_loaded = true
      end

      # :nodoc:
      def self.__preload_{{name}}(records : Array({{@type}})) : Nil
        keys = records.compact_map(&.{{fk}}?).uniq
        found = keys.empty? ? [] of {{klass}} : {{klass}}.where_in({{primary_key}}, keys).to_a
        index = found.index_by(&.{{primary_key.id}})
        records.each { |r| r.__set_{{name}}(r.{{fk}}?.try { |k| index[k]? }) }
      end

      {% if counter_cache %}
        # :nodoc: keeps the parent's counter in sync. A row counts while it has a
        # parent and is not soft deleted: compare before and after the change.
        def __counter_cache_{{name}}(event : Symbol, changed : Hash(String, {::Silth::DB::Value, ::Silth::DB::Value})) : Nil
          trashed = !read_attribute("deleted_at").nil?
          key = ::Silth::DB.as_i64?(read_attribute({{fk.stringify}}))
          old_key = (c = changed[{{fk.stringify}}]?) ? ::Silth::DB.as_i64?(c[0]) : key
          old_trashed = (d = changed["deleted_at"]?) ? !d[0].nil? : trashed
          before = event == :create || old_trashed ? nil : old_key
          after = event == :delete || trashed ? nil : key
          return if before == after
          counter = {% if counter_cache == true %}"#{self.class.table_name}_count"{% else %}{{counter_cache.id.stringify}}{% end %}
          before.try { |k| ::Silth::DB::QueryBuilder.new({{klass}}.table_name, {{klass}}.database).where({{primary_key.id}}: k).increment(counter, -1) }
          after.try { |k| ::Silth::DB::QueryBuilder.new({{klass}}.table_name, {{klass}}.database).where({{primary_key.id}}: k).increment(counter, 1) }
        end
      {% end %}
    end

    # :nodoc:
    macro __polymorphic_belongs_to(decl, optional)
      {% if decl.is_a?(TypeDeclaration) %}
        {% name = decl.var %}
        {% types = decl.type.is_a?(Union) ? decl.type.types : [decl.type] %}
        {% target = (types.size == 1 ? types[0] : "::Silth::Model").id %}
      {% else %}
        {% name = decl.id %}
        {% types = nil %}
        {% target = "::Silth::Model".id %}
      {% end %}
      column {{name}}_type : String{% if optional %}?{% end %}
      column {{name}}_id : Int64{% if optional %}?{% end %}
      @__rel_{{name}} : ({{target}})? = nil
      @__rel_{{name}}_loaded = false

      def {{name}} : ({{target}})?
        return @__rel_{{name}} if @__rel_{{name}}_loaded
        @__rel_{{name}}_loaded = true
        @__rel_{{name}} = self.class.__polymorphic_{{name}}(@{{name}}_type, @{{name}}_id.try { |i| [i] } || [] of Int64).values.first?
      end

      def {{name}}! : {{target}}
        {{name}} || raise ::Silth::ORM::RecordNotFound.new(@{{name}}_type.to_s, "id=#{@{{name}}_id}")
      end

      def {{name}}=(record : ({{target}})?) : Nil
        {% if types && types.size > 1 %}
          if record && !({{types.map { |t| "record.is_a?(#{t})" }.join(" || ").id}})
            raise ArgumentError.new("#{record.class.name} is not a valid {{name}} for #{self.class.name} (expected {{types.join(" | ").id}})")
          end
        {% end %}
        @__rel_{{name}} = record
        @__rel_{{name}}_loaded = true
        self.{{name}}_type = record.try(&.class.name)
        self.{{name}}_id = record.try { |r| ::Silth::DB.as_i64?(r.read_attribute(r.__primary_key_name)) }
      end

      # :nodoc:
      def __set_{{name}}(record : ({{target}})?) : Nil
        @__rel_{{name}} = record
        @__rel_{{name}}_loaded = true
      end

      # :nodoc: records of class *type* by primary key.
      def self.__polymorphic_{{name}}(type : String?, ids : Array(Int64)) : Hash(Int64, {{target}})
        found = {} of Int64 => {{target}}
        return found if type.nil? || ids.empty?
        {% if types %}
          case type
          {% for t in types %}
            when {{t}}.name
              {{t}}.where_in({{t}}.primary_key_name, ids).to_a.each { |r| found[::Silth::DB.as_i64(r.read_attribute(r.__primary_key_name))] = r }
          {% end %}
          else
            raise ::Silth::Error.new("#{type} is not a valid {{name}} for #{self.name} (expected {{types.join(" | ").id}})")
          end
        {% else %}
          ::Silth::Model.__find_polymorphic(type, ids).each { |k, r| found[k] = r }
        {% end %}
        found
      end

      # :nodoc:
      def self.__preload_{{name}}(records : Array({{@type}})) : Nil
        records.group_by(&.{{name}}_type?).each do |type, group|
          found = __polymorphic_{{name}}(type, group.compact_map(&.{{name}}_id?).uniq)
          group.each { |r| r.__set_{{name}}(r.{{name}}_id?.try { |k| found[k]? }) }
        end
      end
    end

    # :nodoc: records of the model named *type* (any model), by primary key.
    def self.__find_polymorphic(type : String, ids : Array(Int64)) : Hash(Int64, Silth::Model)
      found = {} of Int64 => Silth::Model
      {% begin %}
        case type
        {% for t in @type.all_subclasses.reject(&.abstract?) %}
          when {{t}}.name
            {{t}}.where_in({{t}}.primary_key_name, ids).to_a.each { |r| found[DB.as_i64(r.read_attribute(r.__primary_key_name))] = r }
        {% end %}
        else
          raise Silth::Error.new("Unknown model #{type} in a polymorphic relation")
        end
      {% end %}
      found
    end

    # `has_many comments : Comment` → `post.comments` returns a chainable query.
    # `has_many tags : Tag, through: "post_tags"` for many-to-many pivot tables.
    # `has_many comments : Comment, as: commentable` for a polymorphic `belongs_to`.
    macro has_many(decl, foreign_key = nil, through = nil, related_key = nil, dependent = nil, as poly = nil)
      {% name = decl.var %}
      {% klass = decl.type %}
      {% owner = @type.name.split("::").last.underscore %}
      {% fk = (foreign_key || (poly ? "#{poly.id}_id" : "#{owner.id}_id")).id %}
      {% morph = poly ? "#{poly.id}_type".id : nil %}
      @__many_{{name}} : Array({{klass}})? = nil

      {% if through %}
        {% rk = (related_key || "#{klass.stringify.split("::").last.underscore.id}_id").id %}
        def {{name}} : ::Silth::ORM::Query({{klass}})
          q = {{klass}}.query
            .select_raw("#{::Silth::Model.q_table({{klass}})}.*")
            .join({{through}}, "#{::Silth::Model.q_col({{through}}, {{rk.stringify}})} = #{::Silth::Model.q_col({{klass}}.table_name, "id")}")
            .where("#{::Silth::Model.q_col({{through}}, {{fk.stringify}})} = ?", id)
          (cached = @__many_{{name}}) ? q.__preloaded(cached) : q
        end

        # Adds pivot rows: `post.attach_{{name}}([1, 2])`.
        def attach_{{name}}(ids : Enumerable) : Nil
          rows = ids.map { |rid| { {{fk.stringify}} => id.as(::Silth::DB::Value), {{rk.stringify}} => ::Silth::DB.to_value(rid) } of String => ::Silth::DB::Value }.to_a
          ::Silth::DB::QueryBuilder.new({{through}}, self.class.database).insert_all(rows)
          @__many_{{name}} = nil
        end

        def detach_{{name}}(ids : Enumerable? = nil) : Nil
          q = ::Silth::DB::QueryBuilder.new({{through}}, self.class.database).where({{fk}}: id)
          q = q.where_in({{rk.stringify}}, ids.to_a) if ids
          q.delete
          @__many_{{name}} = nil
        end

        # Replaces the pivot rows with exactly `ids`.
        def sync_{{name}}(ids : Enumerable) : Nil
          self.class.database.transaction do
            detach_{{name}}
            attach_{{name}}(ids) unless ids.empty?
          end
        end

        # :nodoc:
        def self.__preload_{{name}}(records : Array({{@type}})) : Nil
          ids = records.compact_map(&.id?)
          return if ids.empty?
          rows = {{klass}}.query
            .select_raw("#{::Silth::Model.q_table({{klass}})}.*, #{::Silth::Model.q_col({{through}}, {{fk.stringify}})} AS __pivot_key")
            .join({{through}}, "#{::Silth::Model.q_col({{through}}, {{rk.stringify}})} = #{::Silth::Model.q_col({{klass}}.table_name, "id")}")
            .where_in({{through}} + "." + {{fk.stringify}}, ids)
            .to_a
          grouped = rows.group_by { |r| ::Silth::DB.as_i64(r["__pivot_key"]) }
          records.each { |r| r.__set_{{name}}(grouped[r.id]? || [] of {{klass}}) }
        end
      {% else %}
        def {{name}} : ::Silth::ORM::Query({{klass}})
          q = {{klass}}.query.where({{fk}}: id).__with_defaults({ {{fk.stringify}} => id.as(::Silth::DB::Value) })
          {% if morph %}
            q = q.where({{morph}}: self.class.name).__with_defaults({ {{morph.stringify}} => self.class.name.as(::Silth::DB::Value) })
          {% end %}
          (cached = @__many_{{name}}) ? q.__preloaded(cached) : q
        end

        # :nodoc:
        def self.__preload_{{name}}(records : Array({{@type}})) : Nil
          ids = records.compact_map(&.id?)
          return if ids.empty?
          children = {{klass}}.where_in({{fk.stringify}}, ids){% if morph %}.where({{morph}}: self.name){% end %}.to_a
          grouped = children.group_by(&.{{fk}}?)
          records.each { |r| r.__set_{{name}}(grouped[r.id]? || [] of {{klass}}) }
        end

        {% if dependent %}
          # :nodoc:
          def __dependent_{{name}} : Nil
            {% if dependent == :destroy %}
              {{name}}.each(&.destroy)
            {% elsif dependent == :delete %}
              {{name}}.delete_all
            {% elsif dependent == :nullify %}
              {{name}}.update_all({{fk}}: nil{% if poly %}, {{poly.id}}_type: nil{% end %})
            {% end %}
          end
        {% end %}
      {% end %}

      # :nodoc:
      def __set_{{name}}(records : Array({{klass}})) : Nil
        @__many_{{name}} = records
      end
    end

    # `has_one profile : Profile`, or `has_one image : Image, as: imageable` (polymorphic).
    macro has_one(decl, foreign_key = nil, dependent = nil, as poly = nil)
      {% name = decl.var %}
      {% klass = decl.type %}
      {% owner = @type.name.split("::").last.underscore %}
      {% fk = (foreign_key || (poly ? "#{poly.id}_id" : "#{owner.id}_id")).id %}
      {% morph = poly ? "#{poly.id}_type".id : nil %}
      @__one_{{name}} : {{klass}}? = nil
      @__one_{{name}}_loaded = false

      def {{name}} : {{klass}}?
        return @__one_{{name}} if @__one_{{name}}_loaded
        @__one_{{name}}_loaded = true
        @__one_{{name}} = {{klass}}.query.where({{fk}}: id){% if morph %}.where({{morph}}: self.class.name){% end %}.first?
      end

      # :nodoc:
      def __set_{{name}}(record : {{klass}}?) : Nil
        @__one_{{name}} = record
        @__one_{{name}}_loaded = true
      end

      # :nodoc:
      def self.__preload_{{name}}(records : Array({{@type}})) : Nil
        ids = records.compact_map(&.id?)
        return if ids.empty?
        index = {{klass}}.where_in({{fk.stringify}}, ids){% if morph %}.where({{morph}}: self.name){% end %}.to_a.index_by(&.{{fk}}?)
        records.each { |r| r.__set_{{name}}(index[r.id]?) }
      end

      {% if dependent == :destroy %}
        # :nodoc:
        def __dependent_{{name}} : Nil
          {{name}}.try(&.destroy)
        end
      {% end %}
    end

    # :nodoc:
    def self.q_table(klass) : String
      klass.database.dialect.quote_table(klass.table_name)
    end

    # :nodoc:
    def self.q_col(table : String, column : String) : String
      DB.connection.dialect.quote_table(table) + "." + DB.connection.dialect.quote(column)
    end

    # --- validations ---------------------------------------------------------------

    # ```
    # validates title, presence: true, length: {min: 3, max: 120}
    # validates email, presence: true, email: true, uniqueness: true
    # validates status, inclusion: ["draft", "published"]
    # validates age, numericality: {greater_than: 0, integer: true}
    # validates slug, format: /\A[a-z0-9-]+\z/, uniqueness: {scope: [:user_id]}
    # ```
    macro validates(field, presence = false, length = nil, format = nil, inclusion = nil, exclusion = nil,
                    numericality = nil, uniqueness = nil, email = false, url = false, confirmation = false,
                    acceptance = false, message = nil, if condition = nil, line = __LINE__)
      # :nodoc:
      def __validation_{{field.id}}_{{line}} : Nil
        {% if condition %} return unless {{condition.id}} {% end %}
        %value = read_attribute({{field.id.stringify}})
        %name = {{field.id.stringify}}
        {% if presence %}
          if ::Silth::Validation.blank?(%value)
            {% if message %} errors.add(%name, {{message}}) {% else %} errors.add_t(%name, "blank") {% end %}
            return
          end
        {% end %}
        return if %value.nil? && !{{presence}}
        {% if length %}
          if %len = ::Silth::Validation.length_of(%value)
            {% if length.is_a?(RangeLiteral) %}
              errors.add_t(%name, "too_short", {{length.begin}}) if %len < {{length.begin}}
              errors.add_t(%name, "too_long", {{length.end}}) if %len > {{length.end}}
            {% else %}
              {% if length[:min] %} errors.add_t(%name, "too_short", {{length[:min]}}) if %len < {{length[:min]}} {% end %}
              {% if length[:max] %} errors.add_t(%name, "too_long", {{length[:max]}}) if %len > {{length[:max]}} {% end %}
              {% if length[:is] %} errors.add(%name, "must be exactly {{length[:is]}} characters") if %len != {{length[:is]}} {% end %}
            {% end %}
          end
        {% end %}
        {% if format %}
          errors.add(%name, {{message || "is invalid"}}) unless %value.to_s.matches?({{format}})
        {% end %}
        {% if email %}
          errors.add_t(%name, "email") unless %value.to_s.matches?(::Silth::Validation::EMAIL)
        {% end %}
        {% if url %}
          errors.add_t(%name, "url") unless %value.to_s.matches?(::Silth::Validation::URL)
        {% end %}
        {% if inclusion %}
          errors.add_t(%name, "inclusion") unless {{inclusion}}.map(&.to_s).includes?(%value.to_s)
        {% end %}
        {% if exclusion %}
          errors.add_t(%name, "exclusion") if {{exclusion}}.map(&.to_s).includes?(%value.to_s)
        {% end %}
        {% if numericality %}
          if %num = ::Silth::Validation.number(%value)
            {% if numericality.is_a?(NamedTupleLiteral) %}
              {% if numericality[:greater_than] != nil %} errors.add_t(%name, "greater_than", {{numericality[:greater_than]}}) unless %num > {{numericality[:greater_than]}} {% end %}
              {% if numericality[:less_than] != nil %} errors.add_t(%name, "less_than", {{numericality[:less_than]}}) unless %num < {{numericality[:less_than]}} {% end %}
              {% if numericality[:integer] %} errors.add(%name, "must be an integer") unless %num == %num.round {% end %}
            {% end %}
          else
            errors.add_t(%name, "not_a_number")
          end
        {% end %}
        {% if acceptance %}
          errors.add_t(%name, "accepted") unless %value == true || %value.to_s.in?("1", "true", "on", "yes")
        {% end %}
        {% if confirmation %}
          if responds_to?(:{{field.id}}_confirmation)
            errors.add_t(%name, "confirmation") unless %value.to_s == {{field.id}}_confirmation.to_s
          end
        {% end %}
        {% if uniqueness %}
          %q = self.class.query.where({ %name => %value })
          {% if uniqueness.is_a?(NamedTupleLiteral) && uniqueness[:scope] %}
            {% for s in uniqueness[:scope] %}
              %q = %q.where({ {{s.id.stringify}} => read_attribute({{s.id.stringify}}) })
            {% end %}
          {% end %}
          %q = %q.where("#{__primary_key_name} <> ?", read_attribute(__primary_key_name)) if persisted?
          errors.add_t(%name, "taken") if %q.exists?
        {% end %}
      end
    end

    # --- hooks (override in your model) ------------------------------------------

    def before_validation; end

    def after_validation; end

    def before_save; end

    def after_save; end

    def before_create; end

    def after_create; end

    def before_update; end

    def after_update; end

    def before_destroy; end

    def after_destroy; end

    # Custom validations: add messages to `errors`.
    def validate; end

    # --- state -----------------------------------------------------------------

    def errors : Validation::Errors
      @__errors ||= Validation::Errors.new
    end

    def persisted? : Bool
      @__persisted && !@__destroyed
    end

    def new_record? : Bool
      !@__persisted
    end

    def destroyed? : Bool
      @__destroyed
    end

    # :nodoc:
    def __mark_persisted : Nil
      @__persisted = true
      @__changes = nil
    end

    # :nodoc:
    def __track_change(name : String, old : DB::Value, new_value : DB::Value) : Nil
      return if old == new_value
      changes = (@__changes ||= {} of String => {DB::Value, DB::Value})
      if existing = changes[name]?
        if existing[0] == new_value
          changes.delete(name)
        else
          changes[name] = {existing[0], new_value}
        end
      else
        changes[name] = {old, new_value}
      end
    end

    def changed? : Bool
      (c = @__changes) ? !c.empty? : false
    end

    def changes : Hash(String, {DB::Value, DB::Value})
      @__changes || {} of String => {DB::Value, DB::Value}
    end

    def attribute_changed?(name : String | Symbol) : Bool
      changes.has_key?(name.to_s)
    end

    # Extra columns selected by the query (aggregates, `distance`, …).
    def [](name : String) : DB::Value
      @__extra.try(&.[name]?) || read_attribute(name)
    end

    def []?(name : String) : DB::Value
      @__extra.try(&.[name]?)
    end

    # --- reflection -------------------------------------------------------------

    def self.primary_key_name : String
      "id"
    end

    # :nodoc:
    def __primary_key_name : String
      {% begin %}
        {% pk = @type.instance_vars.find { |iv| (a = iv.annotation(::Silth::Model::Column)) && a[:primary] } %}
        {% if pk %} {{pk.annotation(::Silth::Model::Column)[:name]}} {% else %} "id" {% end %}
      {% end %}
    end

    def column_names : Array(String)
      {% begin %}
        [{% for iv in @type.instance_vars %}{% if a = iv.annotation(::Silth::Model::Column) %}{{a[:name]}}, {% end %}{% end %}] of String
      {% end %}
    end

    def read_attribute(name : String) : DB::Value
      {% begin %}
        case name
        {% for iv in @type.instance_vars %}
          {% if a = iv.annotation(::Silth::Model::Column) %}
            when {{a[:name]}}{% if a[:name] != iv.name.stringify %}, {{iv.name.stringify}}{% end %} then ::Silth::ORM::Cast.to_db(@{{iv.name}})
          {% end %}
        {% end %}
        else
          @__extra.try(&.[name]?)
        end
      {% end %}
    end

    # Assigns a database or form value (cast to the column type).
    def write_attribute(name : String, value : DB::Value) : Bool
      {% begin %}
        case name
        {% for iv in @type.instance_vars %}
          {% if a = iv.annotation(::Silth::Model::Column) %}
            when {{a[:name]}}{% if a[:name] != iv.name.stringify %}, {{iv.name.stringify}}{% end %}
              self.{{iv.name}} = ::Silth::ORM::Cast.cast(value, {{a[:type]}})
              return true
          {% end %}
        {% end %}
        end
        false
      {% end %}
    end

    def attributes : Hash(String, DB::Value)
      {% begin %}
        h = {} of String => DB::Value
        {% for iv in @type.instance_vars %}
          {% if a = iv.annotation(::Silth::Model::Column) %}
            h[{{a[:name]}}] = ::Silth::ORM::Cast.to_db(@{{iv.name}})
          {% end %}
        {% end %}
        h
      {% end %}
    end

    # Mass assignment from form params (strings are cast). Unknown keys are ignored.
    #
    # ```
    # post.assign(params.permit(:title, :body, from: :post))
    # ```
    def assign(values : Hash(String, String)) : self
      values.each do |k, v|
        begin
          write_attribute(k, v)
        rescue ORM::Cast::CastError
          errors.add_t(k, "invalid")
        end
      end
      self
    end

    def assign(**attrs : **T) : self forall T
      {% for key in T.keys %}
        self.{{key.id}} = attrs[{{key.symbolize}}]
      {% end %}
      self
    end

    def initialize(**attrs)
      assign(**attrs)
    end

    # :nodoc:
    def __load_row(columns : Array(String), row : Array(DB::Value)) : Nil
      {% begin %}
        columns.each_with_index do |col, i|
          value = row[i]?
          case col
          {% for iv in @type.instance_vars %}
            {% if a = iv.annotation(::Silth::Model::Column) %}
              when {{a[:name]}} then @{{iv.name}} = ::Silth::ORM::Cast.cast(value, {{a[:type]}})
            {% end %}
          {% end %}
          else
            (@__extra ||= {} of String => DB::Value)[col] = value
          end
        end
      {% end %}
    end

    # :nodoc:
    def __preload(records, name : String) : Nil
      {% begin %}
        case name
        {% for m in @type.class.methods.select { |m| m.name.starts_with?("__preload_") } %}
          when {{m.name.stringify[10..-1]}} then self.class.{{m.name.id}}(records)
        {% end %}
        else
          raise ::Silth::Error.new("Unknown association '#{name}' on #{self.class.name}")
        end
      {% end %}
    end

    # --- validation ----------------------------------------------------------------

    def valid? : Bool
      errors.clear
      before_validation
      {% begin %}
        {% for t in [@type] + @type.ancestors %}
          {% for m in t.methods.select { |m| m.name.starts_with?("__validation_") } %}
            {{m.name.id}}
          {% end %}
        {% end %}
      {% end %}
      validate
      after_validation
      errors.empty?
    end

    def invalid? : Bool
      !valid?
    end

    # --- persistence ------------------------------------------------------------------

    # Validates, runs the hooks and writes the record.
    #
    # The write is wrapped in a transaction only when the model has hooks,
    # counter caches or dependents that run more statements: a lone `INSERT …
    # RETURNING` or `UPDATE` is atomic already, and skipping `BEGIN`/`COMMIT`
    # saves two round trips (decided at compile time).
    def save(validate : Bool = true) : Bool
      return false if validate && !valid?
      if __transactional_save?
        self.class.database.transaction { __persist }
      else
        __persist
      end
      true
    end

    private def __persist : Nil
      before_save
      if new_record?
        before_create
        __insert
        after_create
      else
        before_update
        __update
        after_update
      end
      after_save
    end

    # :nodoc: whether saving runs more than one statement (hooks, counter caches).
    def __transactional_save? : Bool
      {% begin %}
        {% hooks = %w(before_save after_save before_create after_create before_update after_update) %}
        {% found = @type.methods.any?(&.name.starts_with?("__counter_cache_")) %}
        {% for t in [@type] + @type.ancestors %}
          {% unless %w(Silth::Model Reference Object).includes?(t.name.stringify) %}
            {% found = true if t.methods.any? { |m| hooks.includes?(m.name.stringify) } %}
          {% end %}
        {% end %}
        {{found}}
      {% end %}
    end

    # :nodoc: whether destroying runs more than one statement (hooks, dependents, counter caches).
    def __transactional_destroy? : Bool
      {% begin %}
        {% found = @type.methods.any? { |m| m.name.starts_with?("__counter_cache_") || m.name.starts_with?("__dependent_") } %}
        {% for t in [@type] + @type.ancestors %}
          {% unless %w(Silth::Model Reference Object).includes?(t.name.stringify) %}
            {% found = true if t.methods.any? { |m| %w(before_destroy after_destroy).includes?(m.name.stringify) } %}
          {% end %}
        {% end %}
        {{found}}
      {% end %}
    end

    def save! : self
      raise ORM::RecordInvalid.new(self.class.name, errors) unless save
      self
    end

    def update(**attrs) : Bool
      assign(**attrs)
      save
    end

    def update!(**attrs) : self
      assign(**attrs)
      save!
    end

    def destroy : Bool
      return false if new_record?
      if __transactional_destroy?
        self.class.database.transaction { __destroy_row }
      else
        __destroy_row
      end
      true
    end

    private def __destroy_row : Nil
      before_destroy
      {% begin %}
        {% for m in @type.methods.select { |m| m.name.starts_with?("__dependent_") } %}
          {{m.name.id}}
        {% end %}
      {% end %}
      if self.class.soft_deletes? && responds_to?(:deleted_at=)
        now = Time.utc
        write_attribute("deleted_at", now)
        __update
      else
        __delete_row
        @__destroyed = true
      end
      after_destroy
    end

    def destroy! : Nil
      raise Silth::Error.new("Failed to destroy #{self.class.name}") unless destroy
    end

    def reload : self
      fresh = self.class.query.with_trashed.where({__primary_key_name => read_attribute(__primary_key_name)}).first
      __load_row(fresh.column_names, fresh.column_names.map { |c| fresh.read_attribute(c) })
      @__changes = nil
      self
    end

    def touch : Bool
      write_attribute("updated_at", Time.utc)
      __update
      true
    end

    def increment!(column : String | Symbol, by : Int = 1) : self
      pk = __primary_key_name
      self.class.query.where({pk => read_attribute(pk)}).increment(column.to_s, by)
      reload
    end

    # :nodoc:
    def __insert : Nil
      db = self.class.database
      now = Time.utc
      {% begin %}
        {% names = @type.instance_vars.map(&.name.stringify) %}
        {% if names.includes?("created_at") %} @created_at ||= now {% end %}
        {% if names.includes?("updated_at") %} @updated_at ||= now {% end %}
        {% for iv in @type.instance_vars %}
          {% if (a = iv.annotation(::Silth::Model::Column)) && a[:uuid] %}
            {% if a[:uuid] == :v4 %}
              @{{iv.name}} ||= UUID.random.to_s
            {% else %}
              @{{iv.name}} ||= ::Silth::Crypto.uuid7
            {% end %}
          {% end %}
        {% end %}
      {% end %}
      values = attributes
      {% begin %}
        {% for iv in @type.instance_vars %}
          {% if (a = iv.annotation(::Silth::Model::Column)) && a[:auto] %}
            values.delete({{a[:name]}}) if @{{iv.name}}.nil?
          {% end %}
        {% end %}
      {% end %}
      d = db.dialect
      table = d.quote_table(self.class.table_name)
      sql = if values.empty?
              d.name == "mysql" ? "INSERT INTO #{table} () VALUES ()" : "INSERT INTO #{table} DEFAULT VALUES"
            else
              "INSERT INTO #{table} (#{values.keys.map { |k| d.quote(k) }.join(", ")}) VALUES (#{(["?"] * values.size).join(", ")})"
            end
      if d.supports_returning?
        result = db.query(sql + " RETURNING *", values.values)
        if row = result.rows.first?
          __load_row(result.columns, row)
        end
      else
        result = db.query(sql, values.values)
        pk = __primary_key_name
        if read_attribute(pk).nil? && (last = result.last_insert_id)
          write_attribute(pk, last)
        end
      end
      __mark_persisted
      __counter_caches(:create)
    end

    # :nodoc:
    def __update : Nil
      changed = changes
      {% begin %}
        {% if @type.instance_vars.map(&.name.stringify).includes?("updated_at") %}
          if !changed.empty? && !changed.has_key?("updated_at")
            @updated_at = Time.utc
            changed = changed.merge({"updated_at" => {nil.as(DB::Value), @updated_at.as(DB::Value)}})
          end
        {% end %}
      {% end %}
      return if changed.empty?
      values = {} of String => DB::Value
      changed.each { |k, v| values[k] = v[1] }
      if lock = self.class.locking_column
        version = __locked_version(changed)
        values[lock] = version + 1
        rows = __row_query(lock, version).update(values)
        raise ORM::StaleObjectError.new(self.class.name, read_attribute(__primary_key_name), version) if rows == 0
        write_attribute(lock, version + 1)
      else
        __row_query.update(values)
      end
      __counter_caches(:update, changed)
      @__changes = nil
    end

    # :nodoc:
    def __delete_row : Nil
      if lock = self.class.locking_column
        version = __locked_version(changes)
        if __row_query(lock, version).delete == 0
          raise ORM::StaleObjectError.new(self.class.name, read_attribute(__primary_key_name), version)
        end
      else
        __row_query.delete
      end
      __counter_caches(:delete)
    end

    # The row of this record (and of its expected lock version).
    private def __row_query(lock : String? = nil, version : Int64? = nil) : DB::QueryBuilder
      pk = __primary_key_name
      query = DB::QueryBuilder.new(self.class.table_name, self.class.database).where({pk => read_attribute(pk)})
      lock ? query.where({lock => version.as(DB::Value)}) : query
    end

    # The lock version read from the database (before any local change to it).
    private def __locked_version(changed : Hash(String, {DB::Value, DB::Value})) : Int64
      lock = self.class.locking_column.not_nil!
      DB.as_i64((c = changed[lock]?) ? c[0] : read_attribute(lock))
    end

    # :nodoc: runs the `counter_cache:` handlers of this model's `belongs_to`.
    def __counter_caches(event : Symbol, changed : Hash(String, {DB::Value, DB::Value}) = {} of String => {DB::Value, DB::Value}) : Nil
      {% begin %}
        {% for m in @type.methods.select { |m| m.name.starts_with?("__counter_cache_") } %}
          {{m.name.id}}(event, changed)
        {% end %}
      {% end %}
    end

    # --- serialization -------------------------------------------------------------------

    # The visible columns (not `hidden: true`) and the extra selected values, as a JSON object.
    def to_json(json : JSON::Builder) : Nil
      json.__silth_raw { |io| __write_json(io) }
    end

    def to_json(io : IO) : Nil
      __write_json(io)
    end

    # :nodoc: writes the object directly: keys are literals, values typed.
    def __write_json(io : IO) : Nil
      io << '{'
      {% begin %}
        {% count = 0 %}
        {% for iv in @type.instance_vars %}
          {% if (a = iv.annotation(::Silth::Model::Column)) && !a[:hidden] %}
            io << {{(count > 0 ? "," : "") + "\"" + a[:name] + "\":"}}
            ::Silth::JSONWriter.value(io, @{{iv.name}})
            {% count = count + 1 %}
          {% end %}
        {% end %}
        first = {{count == 0}}
        @__extra.try &.each do |k, v|
          next if k.starts_with?("__")
          io << ',' unless first
          first = false
          ::Silth::JSONWriter.string(io, k)
          io << ':'
          ::Silth::JSONWriter.value(io, v)
        end
      {% end %}
      io << '}'
    end

    def to_h : Hash(String, DB::Value)
      attributes
    end

    def ==(other : self) : Bool
      return same?(other) if new_record? || other.new_record?
      read_attribute(__primary_key_name) == other.read_attribute(__primary_key_name)
    end

    def inspect(io : IO) : Nil
      io << '#' << self.class.name << '('
      attributes.each_with_index do |(k, v), i|
        io << ", " unless i == 0
        io << k << ": "
        v.inspect(io)
      end
      io << ')'
    end
  end
end
