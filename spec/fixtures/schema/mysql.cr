# Database schema, written by `silth db:schema:dump` (and after migrations in development).
# Do not edit it: change the schema with migrations. `silth db:schema:load` recreates the
# database from this file, much faster than running every migration.
Silth::DB::SchemaDefinition.define(version: 20260101000001, connection: "fixture_mysql") do |s|
  s.create_table "authors" do |t|
    t.id
    t.string "name", null: false, limit: 255
  end

  s.create_table "events" do |t|
    t.id :uuid
    t.column "kind", :"enum('a','b')", null: false, default: "a"
    t.column "hits", :"int unsigned"
    t.text "body"
    t.column "body_size", :integer, generated: "char_length(`body`)"
  end

  s.create_table "note_tags" do |t|
    t.bigint "note_id", null: false
    t.bigint "tag_id", null: false
    t.primary_key ["note_id", "tag_id"]
    t.index ["tag_id"], name: "tag_id"
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
    t.fulltext ["title", "body"], name: "fulltext_notes_on_title_and_body"
    t.index ["author_id"], name: "index_notes_on_author_id"
    t.index ["deleted_at"], name: "index_notes_on_deleted_at"
  end

  s.create_table "tags" do |t|
    t.id
    t.string "slug", null: false, limit: 80
    t.decimal "weight", precision: 8, scale: 3, default: 1.500
    t.boolean "active", default: true
    t.json "data", default: :empty_json
    t.timestamp "seen_at", default: :now
    t.string "label", default: "it's \"quoted\" \#{not interpolated}", limit: 255
    t.index ["slug"], unique: true, name: "slug"
  end

  s.add_foreign_key "note_tags", "note_id", "notes", on_delete: :cascade, name: "note_tags_ibfk_1"
  s.add_foreign_key "note_tags", "tag_id", "tags", on_delete: :cascade, on_update: :cascade, name: "note_tags_ibfk_2"
  s.add_foreign_key "notes", "author_id", "authors", on_delete: :nullify, name: "notes_ibfk_1"
end
