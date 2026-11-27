---
name: silth
description: Build and modify web applications with the Silth framework for Crystal (routes, models/ORM, migrations, controllers, ECR templates, components, live components, jobs, mail, auth, policies, tests). Use whenever the project's shard.yml depends on `silth`, files `require "silth"`, or the user mentions Silth.
---

# Building with Silth

Silth is an MVC web framework for Crystal with zero third-party shards. Full docs: https://silth.dev/docs — every page exists as Markdown (append `.md`), index at https://silth.dev/llms.txt.

## Workflow

1. Read `AGENTS.md` at the project root, then `config/routes.cr` (or `silth routes --json`).
2. Prefer generators, then refine: `silth g scaffold Post title:string 'body:text?' 'user:references?'`.
3. After changing models: write a migration (`silth g migration …`), run `silth db:migrate`.
4. After each change, `silth check` type-checks the whole app in a few seconds without building it. Before finishing: `crystal tool format`, then `silth test` (or `crystal spec`). Fix every compiler error — they point to exact lines, including inside templates.

## Golden rules

- **Templates are compiled.** `render "posts/index", posts: posts` embeds `src/views/posts/index.html.ecr` at compile time; locals must be passed explicitly. `<%= %>` escapes, `<%== %>` is raw.
- **Block helpers use control tags**: `<% form_with url: …, model: post do |f| %> … <% end %>` and `<% component CardComponent, title: "x" do %> … <% end %>`.
- **Non-nilable model getters raise** when the value is missing (`post.title`). Use `post.title?` for a nilable read; `Bool` columns: `post.published?` returns Bool.
- **Mass assignment** goes through `params.permit(:title, :body, from: :post)` then `model.assign(hash)`.
- **Raw SQL** always uses `?` placeholders (converted per database). Never interpolate user input.
- **Symbols are columns, Strings are SQL** in queries: `where(:views, ">", 10)` vs `where("lower(title) = ?", t)`.
- Base classes must be required before subclasses (`src/app.cr` handles it; new top-level directories need a `require "./dir/**"` line).
- Quote nullable generator fields in shells: `'body:text?'`.
- Callbacks are plain methods you override: `def before_save; …; end`.
- Money is `Decimal`, never `Float64`: `column total : Decimal`, `Decimal.new("12.50")`, `amount.round(2)`. Calendar dates are `Date` (`column due_on : Date`).

## Cheat sheet

```crystal
# config/routes.cr
Silth.routes do
  get "/", HomeController, :index, name: "home"
  resources "posts", PostsController                 # only actions that exist
  scope "/admin", name: "admin", middleware: [:auth] do … end
  api do resources "posts", Api::PostsController, except: [:new, :edit] end
  live "/search", SearchComponent
end

# Model
class Post < ApplicationModel
  primary_key
  column title : String
  column body : String?
  column views : Int32 = 0
  timestamps
  belongs_to user : User
  has_many comments : Comment, dependent: :destroy
  validates title, presence: true, length: {min: 3, max: 120}
  scope published { where(published: true) }
end
Post.published.where(user_id: id).includes(:user).latest.paginate(page, 20)

# Controller
class PostsController < ApplicationController
  before_action :authenticate!, except: [:index, :show]
  def show
    post = Post.find(params["id"])            # 404 when missing
    authorize! :view, post                    # PostPolicy#view?
    render "posts/show", post: post
  end
end

# Migration (`change` is rolled back automatically; use up/down for raw SQL)
class CreatePosts < Silth::Migration
  version 2026_11_24_120000
  def change
    create_table :posts do |t|
      t.id
      t.references :user
      t.string :title, null: false
      t.text :body
      t.timestamps
    end
  end
end
```

More: `references/api-cheatsheet.md` (every module in one page) and `references/recipes.md` (step-by-step tasks).

## Testing

```crystal
describe PostsController do
  it "creates" do
    client.acting_as(UserFactory.create)
    client.post("/posts", form: {"post[title]" => "Hello"}).should be_redirect
  end
end
```

Fakes: `Silth::Mailer.sent`, `Silth::Queue.fake`, `Silth::Events.fake`, `Silth::Storage.fake`, `Silth::HTTPClient.fake(...)`.

## Debugging

- Dev error page shows the failing source line; the profiler (`/_silth/profiler/<token>`, token in the `X-Silth-Profile` header) has a timeline of the request plus queries (duplicates = N+1), logs, translations (missing keys) and events panels (`?panel=queries|logs|translations|events|request`).
- CLI errors: re-run with `SILTH_TRACE=1`.
- `silth about` prints drivers and configuration.
