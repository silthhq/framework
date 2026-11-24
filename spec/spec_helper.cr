ENV["SILTH_ENV"] = "test"
require "spec"
require "../src/silth"
require "../src/silth/testing"

Silth.config = Silth::Config.new
Silth.app_key = "base64:" + Base64.strict_encode("0" * 32)
Silth::DB.register("primary", ENV["SILTH_TEST_DATABASE_URL"]? || "sqlite3::memory:", 2)

class CreateNotes < Silth::Migration
  version 2026_01_01_000001

  def up
    create_table :authors do |t|
      t.id
      t.string :name, null: false
    end
    create_table :notes do |t|
      t.id
      t.references :author, null: true, on_delete: :nullify
      t.string :title, null: false
      t.text :body
      t.integer :views, default: 0
      t.boolean :pinned, default: false
      t.string :status, default: "draft"
      t.json :meta
      t.timestamps
      t.soft_deletes
      t.fulltext [:title, :body]
    end
  end

  def down
    drop_table :notes
    drop_table :authors
  end
end

class Author < Silth::Model
  primary_key
  column name : String
  has_many notes : Note
end

class Note < Silth::Model
  primary_key
  column title : String
  column body : String?
  column views : Int32 = 0
  column pinned : Bool = false
  column status : String = "draft"
  column meta : JSON::Any?
  timestamps
  soft_deletes
  belongs_to author : Author, optional: true

  validates title, presence: true, length: {min: 2, max: 50}
  scope pinned { where(pinned: true) }
  scope popular { |min| where(:views, ">=", min) }
end

class CardComponent < Silth::Component
  prop title : String
  template "spec/fixtures/views/card.html.ecr"
end

class CounterLive < Silth::LiveComponent
  prop count : Int32 = 0
  prop step : Int32 = 1, writable: true
  template "spec/fixtures/views/counter.html.ecr"

  action def increment
    @count = count + step
  end

  action def add(amount : Int32)
    @count = count + amount
  end
end

class NotesController < Silth::Controller
  LAYOUT = false
  before_action :mark, only: [:index]

  def index
    json Note.order(id: :asc).to_a
  end

  def show
    note = Note.find(params["id"])
    render "spec/fixtures/views/form.html.ecr", note: note
  end

  def hello
    render "spec/fixtures/views/hello.html.ecr", layout: "spec/fixtures/views/layout.html.ecr", name: "<Ada>", raw_html: "<b>ok</b>", items: ["a", "b"]
  end

  def create
    note = Note.new.assign(params.permit(:title, :body, from: :note))
    if note.save
      redirect "/notes/#{note.id}"
    else
      json({errors: note.errors}, 422)
    end
  end

  def boom
    raise "kaboom"
  end

  private def mark
    response.headers["X-Filtered"] = "yes"
  end
end

Silth.routes do
  get "/hello", NotesController, :hello
  resources "notes", NotesController
  get "/boom", NotesController, :boom
  get "/ping" { |ctx| ctx.text "pong" }
  get "/files/*path" { |ctx| ctx.text ctx.route_params["path"] }
  get "/items/:id<\\d+>" { |ctx| ctx.text "item #{ctx.route_params["id"]}" }
  scope "/admin", name: "admin", middleware: [:auth] do
    get "/", NotesController, :index, name: "home"
  end
  api do
    get "/notes", NotesController, :index
  end
end

Silth::Testing.setup(fresh: true)
Silth::I18n.load("spec/fixtures/locales")
