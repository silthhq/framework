# Database schema, written by `silth db:schema:dump` (and after migrations in development).
# Do not edit it: change the schema with migrations. `silth db:schema:load` recreates the
# database from this file, much faster than running every migration.
Silth::DB::SchemaDefinition.define(version: 20260101000001, connection: "fixture_sqlite") do |s|
  s.create_table "authors" do |t|
    t.id
    t.string "name", null: false, limit: 255
  end

  s.create_table "note_tags" do |t|
    t.integer "note_id", null: false
    t.integer "tag_id", null: false
    t.primary_key ["note_id", "tag_id"]
    t.foreign_key "note_id", "notes", on_delete: :cascade
    t.foreign_key "tag_id", "tags", on_delete: :cascade, on_update: :cascade
  end

  s.create_table "notes" do |t|
    t.id
    t.integer "author_id"
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
    t.foreign_key "author_id", "authors", on_delete: :nullify
  end

  s.create_table "tags" do |t|
    t.id
    t.string "slug", null: false, limit: 80, unique: true
    t.column "weight", :decimal, default: 1.5
    t.boolean "active", default: true
    t.json "data", default: :empty_json
    t.timestamp "seen_at", default: :now
    t.text "note", default: "it's \"quoted\" \#{not interpolated}"
    t.string "label", default: "it's \"quoted\" \#{not interpolated}", limit: 255
  end

  s.execute "CREATE INDEX index_tags_on_lower_slug ON tags (lower(slug))"
  s.execute "CREATE INDEX \"index_tags_on_weight\" ON \"tags\" (\"weight\") WHERE active = 1"
end
