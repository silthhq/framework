# Database schema, written by `silth db:schema:dump` (and after migrations in development).
# Do not edit it: change the schema with migrations. `silth db:schema:load` recreates the
# database from this file, much faster than running every migration.
Silth::DB::SchemaDefinition.define(version: 20260101000001, connection: "fixture_postgres") do |s|
  s.create_table "authors" do |t|
    t.id
    t.string "name", null: false, limit: 255
  end

  s.create_table "events" do |t|
    t.id :uuid
    t.string_array "labels"
    t.integer_array "counts"
    t.column "happened_at", :"timestamp without time zone"
    t.column "raw_json", :"JSON"
    t.text "body"
    t.column "search", :tsvector, generated: "to_tsvector('english'::regconfig, COALESCE(body, ''::text))"
    t.index ["labels"], name: "index_events_on_labels", using: "gin"
    t.index ["search"], name: "index_events_on_search", using: "gin"
  end

  s.create_table "note_tags" do |t|
    t.bigint "note_id", null: false
    t.bigint "tag_id", null: false
    t.primary_key ["note_id", "tag_id"]
  end

  s.create_table "notes" do |t|
    t.id
    t.bigint "author_id"
    t.string "title", null: false, limit: 255
    t.text "body"
    t.integer "views", default: 0
    t.boolean "pinned", default: false
    t.string "status", default: "draft", limit: 255
    t.json "meta"
    t.timestamp "created_at"
    t.timestamp "updated_at"
    t.timestamp "deleted_at"
    t.index ["author_id"], name: "index_notes_on_author_id"
    t.index ["deleted_at"], name: "index_notes_on_deleted_at"
  end

  s.create_table "tags" do |t|
    t.id
    t.string "slug", null: false, limit: 80
    t.decimal "weight", precision: 8, scale: 3, default: 1.5
    t.boolean "active", default: true
    t.json "data", default: :empty_json
    t.timestamp "seen_at", default: :now
    t.text "note", default: "it's \"quoted\" \#{not interpolated}"
    t.string "label", default: "it's \"quoted\" \#{not interpolated}", limit: 255
    t.index ["weight"], name: "index_tags_on_weight", where: "active"
    t.index ["slug"], unique: true, name: "tags_slug_key"
  end

  s.create_table "visits", unlogged: true do |t|
    t.id
    t.string "path", null: false, limit: 255
  end

  s.add_foreign_key "note_tags", "note_id", "notes", on_delete: :cascade, name: "note_tags_note_id_fkey"
  s.add_foreign_key "note_tags", "tag_id", "tags", on_delete: :cascade, on_update: :cascade, name: "note_tags_tag_id_fkey"
  s.add_foreign_key "notes", "author_id", "authors", on_delete: :nullify, name: "notes_author_id_fkey"
  s.execute "CREATE INDEX fulltext_notes_on_title_and_body ON notes USING gin (to_tsvector('english'::regconfig, ((COALESCE((title)::text, ''::text) || ' '::text) || COALESCE(body, ''::text))))"
  s.execute "CREATE INDEX index_tags_on_lower_slug ON tags USING btree (lower((slug)::text))"
end
