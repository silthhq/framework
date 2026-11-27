# Silth API cheat sheet

## Config & env
`Silth.config.string("app.name")`, `.int("server.port", 3000)`, `.bool`, `.array`, `.hash`, `.bind("mail", MailSettings)`. YAML supports `${VAR:-default}` and `when@production:` blocks. `Silth.env`, `Silth.production?`.
JSON times: `json_time_precision: 3|auto|0|6|9` in config/app.yml (RFC 3339 UTC `…Z`; `auto` = no fraction for whole seconds, else 3/6/9 digits like Rust's chrono). Server: `workers: 4|auto` in config/server.yml (`WEB_CONCURRENCY`, `bin/<app> server -w auto`) runs supervised processes on one port (SO_REUSEPORT).

## Context / controller
params: `params["id"]`, `params["q"]?`, `params.int("page", 1)`, `params.permit(:a, from: :post)`, `params.file("avatar")`, `params.json`.
responses: `render`, `json(obj, status)`, `text`, `redirect(url, notice:)`, `redirect_back`, `head(204)`, `send_file`, `stream`, `sse`, `problem(422, "Title")`.
state: `session[...]`, `flash["notice"]`, `ctx.set_signed_cookie`, `ctx.auth_user`, `ctx.locale`.
filters: `before_action :m, only: [...]`, `after_action`, `rescue_from Klass, with: :handler`.
validation: `data = validate!(CreatePostRequest)` (FormRequest with `field title : String, min: 3`).

## ORM
CRUD: `create!`, `save`, `save!`, `update`, `destroy`, `find`, `find?`, `find_by`, `first_or_create`, `reload`, `touch`, `increment!`. A save runs in a transaction only when the model has hooks or counter caches.
Types: `column total : Decimal` (NUMERIC/DECIMAL, exact, keeps its scale: JSON `"12.50"`; `Decimal.new("19.90") * 3`, `.round(2)` half-even, `.round(2, :ties_away)`, `.truncate(2)`, `.rescale(2)`, `.to_fixed(2)`, `.normalize`, `/` stops at 28 places), `column due_on : Date` (DATE, JSON `"2026-11-27"`; `Date.today`, `+ 30`, `shift(months: 1)`, `at_end_of_month`, `d1 - d2` days, ranges). `BigDecimal` columns work too. Exact sums: `query.sum_decimal(:total)`.
Query: `where`, `or_where`, `where_not`, `where_in`, `where_null`, `where_between`, `where_like`, `where_group { |g| … }`, `join`, `order(created_at: :desc)`, `latest`, `limit`, `offset`, `group_by`, `having`, `select`, `distinct`, `includes(:rel)`, `with_trashed`, `lock_for_update(skip_locked: true)`.
Fetch: `to_a`, `first`, `first?`, `last`, `count`, `exists?`, `pluck`, `sum/avg/min/max`, `paginate(page, per)`, `cursor_paginate`, `find_each`.
PostgreSQL: `search([:title, :body], q)`, `order_by_relevance`, `nearest(:embedding, vec, metric: :cosine)`, `select_distance`, `where_json`, `where_json_contains`.
Relations: `belongs_to x : X, optional: true, counter_cache: true` (X.<table>_count), polymorphic `belongs_to commentable : Post | Video, polymorphic: true` + `has_many comments : Comment, as: commentable` (reader returns `Silth::Model?`), `has_many xs : X, through: "pivot", dependent: :destroy`, `has_one`. Many-to-many: `attach_tags`, `detach_tags`, `sync_tags`.
Locking: `optimistic_locking` + `t.lock_version` → `Silth::ORM::StaleObjectError` on concurrent update/destroy.
Validations: presence, length, format, email, url, inclusion, exclusion, numericality, uniqueness (`{scope: [...]}`), confirmation, acceptance, `if:`. Custom: `def validate; errors.add("f", "msg"); end`.
Raw: `Silth::DB.query(sql, args).to_hashes`, `Silth::DB.table("x")…`, `Silth::DB.transaction { }`. Read replicas: `replicas: [url, …]` per connection in `config/database.yml` (reads to replicas, writes/transactions to the primary, sticky after a write; `sticky_for` seconds via cookie), `Silth::DB.on_primary { }` forces the primary.
Migrations: `def change` (create_table, add_column, rename_column, add_index, add_foreign_key, enable_extension… are reversed automatically; `remove_column :t, :c, :string` and `drop_table :t do |t| … end` too), `reversible { |dir| dir.up { execute "…" }; dir.down { … } }`, or `up`/`down`. `db/schema.cr` (`Silth::DB::SchemaDefinition.define(version: …) do |s| … end`) is rewritten after migrations in development; `silth db:schema:load` rebuilds the database from it.
PostgreSQL UNLOGGED drivers: cache `default: postgres` (config/cache.yml), sessions `driver: postgres` (config/session.yml), logs `postgres: {connection: primary, level: warn, retention_days: 14}` (config/logging.yml); `create_table :x, unlogged: true`.
PostgreSQL URL options: statements are prepared once per connection (`?statement_cache_size=256`), `?prepared_statements=false` behind PgBouncer in transaction mode. Pools hand connections to the longest waiting fiber under contention (bounded p99).
MySQL URL options: `?ssl=true`, `?statement_cache_size=256` (prepared statements per connection, `0` = close after use), `?prepared_statements=false` (client-side interpolation), `?server_public_key=path.pem` (pin the RSA key for `caching_sha2_password` without TLS), `?allow_cleartext_password=true` (LDAP/PAM over plain TCP, refused by default). Auth plugins: native, `caching_sha2_password`, `sha256_password`, MariaDB `ed25519` and `parsec`.

## Views
Helpers: `link_to`, `button_to(text, url, method: "delete", confirm:)`, `route(name, **params)`, `form_with`, `f.text_field/text_area/select/check_box/errors_for/submit`, `t`, `l`, `paginate`, `flash_messages`, `partial "dir/_x", local: v`, `content_for`, `yield_content`, `component`, `live`, `stylesheet_tag`, `importmap_tags`, `silth_scripts`, `csrf_meta_tags`.

## Components
`class X < Silth::Component; prop title : String; template "components/x"; end` → `<%= component X, title: "…" %>`, slot via `<%= yield_slot %>`; named slots: `<% component X do |x| %><% x.slot :footer do %>…<% end %>…<% end %>` + `<%= yield_slot :footer %>`, `slot?(:footer)`.
Previews: `class XPreview < Silth::ComponentPreview; description "…"; def default : Silth::Component; X.new(title: "…").with_slots(content: "<p>…</p>", footer: "…"); end; end` (src/components/previews) → /_silth/profiler/components (props editable, widths, usage). `component.prop_specs`, `with_slots`, `fill_slot`, override `preview_usage` for a custom snippet.
UI kit (new apps, src/components/ui): `<% component UI::Dialog, id: "x", title: "…", trigger: "Open" do |d| %>…<% d.slot :actions do %>…<% end %><% end %>` (`open: true`, `close_action:` in live components, `<button data-ui-dialog="x">` opens it); `<% component UI::Dropdown, label: "…" do |menu| %><% menu.item "Edit", href: … %><% menu.item "Archive", action: "archive" %><% end %>`; `<% component UI::Tabs, label: "…" do |tabs| %><% tabs.tab "key", "Label" do %>…<% end %><% end %>`; toasts: `<%= component UI::Toaster %>` in the layout, `emit "toast", {message: "…", variant: "success"}`, JS `ui.toast(…)`. Morphing keeps client-owned attributes listed in `silth-keep="open hidden"`.
Live: `class Y < Silth::LiveComponent; prop q : String = "", writable: true; action def go; …; end; end`. Directives: `silth-click`, `silth-args`, `silth-submit`, `silth-model(.debounce.300ms|.lazy)`, `silth-change`, `silth-keydown.enter`, `silth-poll`, `silth-confirm`, `data-key`. Server push: `def subscriptions; ["topic"]; end` + `Silth::Live.refresh("topic")` (several nodes: `pubsub: redis|postgres` in config/realtime.yml). Browser events: `emit("name", payload)` → `window` event `silth:name`. Uploads: `prop avatar : Silth::Live::Upload?, writable: true` + `<input type="file" silth-model="avatar">` → `avatar.preview_url`, `avatar.store("avatars")`. Nested: `<%= live Child, key: item.id, … %>` in a live template, child calls `notify_parent("action", *args)`.

## Auth & authorization
`include Silth::Auth::Authenticatable` (needs `password_digest`). `auth.attempt(email, pw, remember:)`, `auth.login(user)`, `auth.logout`, `user.create_token("cli", ["posts:read"])`, `Silth::JWT.encode(claims, secret, expires_in:, algorithm: "HS512")` / `decode(token, secret, algorithms: ["HS512"])` (HS256/384/512, default `auth.jwt_algorithm`), `Silth::Auth::TOTP`, `Silth::Auth.password_reset_token(user)`. Middleware aliases: `:auth`, `:guest`, `:verified`, `:signed`, `:throttle`.
Passwords: `Silth::Password.hash/verify/needs_rehash?`; `auth.password_algorithm: bcrypt|argon2id` (config/auth.yml, `argon2: {memory: 19456, iterations: 2, parallelism: 1}`); bcrypt and Argon2 hashes (PHC `$argon2id$v=19$…` from any implementation) always verify; a login re-hashes a password stored with other settings (`rehash_on_login`). `Silth::Argon2.hash/verify`, `Silth::Blake2b.digest`.
Policies: `class PostPolicy < Silth::Policy; def update?(user : User, post : Post) : Bool; end; end`, `authorize! :update, post`, `can?(:update, post)`, `Silth::Gate.define("admin") { |u| … }`.

## Services
Cache: `Silth.cache.fetch(key, 10.minutes) { … }`, `lock`, `increment`.
Events: `Silth::Events.listen(E) { |e| }`, `dispatch`, `Listener(E)` classes (`queued`).
Jobs: `class J < Silth::Job; queue "q"; retries 3; def perform : Nil; end; end`, `J.new(…).dispatch(delay: 5.minutes)` (→ `String?`), `silth queue:work`. `unique for: 10.minutes` (duplicates skipped, `unique_key`), `rate_limit 30, per: 1.minute`, queue limits `rate_limits: {mail: 10/1s}` in config/queue.yml. Batches: `Silth::Batch.dispatch(jobs, on_success: J.new, on_failure: J.new, on_complete: J.new, allow_failures: false)`, `batch.progress`, `batch.cancel`, `batch` inside jobs.
Schedule: `Silth.schedule { |s| s.job(J.new).daily_at("03:00") }`.
Mail: `class M < Silth::Mail; def build : Nil; to …; subject …; html render_to_string("mails/x", layout: "layouts/mail", …); end; end`, `.deliver` / `.deliver_later`. Markdown: `markdown "mails/x", user: u` (src/views/mails/x.md.ecr, `<%= button "Label", url %>`, `<%= panel "…" %>`, text body generated). Previews: `class MPreview < Silth::MailPreview; def x : Silth::Mail; M.new(…); end; end` → /_silth/profiler/mails.
Notifications: `class N < Silth::Notification; def via(n) : Array(Symbol); [:mail, :database]; end; end`, `user.notify(N.new)`.
Storage: `Silth.storage.put/get?/read/url/temporary_url/put_file`, disks local|s3|memory.
HTTP: `Silth::HTTPClient.new.bearer(t).retry(3).get(url).json`; files: `post(path, multipart: [{"files", Silth::HTTPClient::File.new("a.html", html, "text/html")}, {"field", "v"}])`, binary bodies `body: bytes`, `response.bytes`.
Concurrency: `Silth::Concurrency.run`, `.map(items, workers: 8)`, `.defer`, `.timeout`, `.retry`.
Realtime: `class C < Silth::Channel; topic "chat:*"; def handle_in(event, payload); broadcast(event, payload); end; end`, `Silth::Broadcast.to(topic, event, payload)`.
Workflows: `config/workflows.yml`, `Silth::Workflow.get("name").apply(model, "transition", user)`.
Billing: `include Silth::Billing::Billable`, `user.checkout(price, success_url:, cancel_url:)`, `user.subscribed?`.
Telemetry: `Silth::Telemetry.trace("name") { |span| }`, `counter`, `histogram`.
Instrumentation (profiler, telemetry): `Silth::Instrument.subscribe { |event| }`, `Instrument.measure("name") { }`, `Instrument.publish(Instrument::Custom.new("name", {"k" => "v"}))`; framework events: Query, Action, Render, Translation (found/fallback/missing), Cache, Mail, Job, AppEvent, HTTPCall, Notification.
Profiler (`config/profiler.yml`): `/_silth/profiler`; each query shows the app line that ran it, repeats from one line = N+1 (fix with `.includes`); `editor: vscode|cursor|zed|idea|…` makes file:line links open in the editor (`SILTH_EDITOR`, `editor_root` in Docker). Sub-requests (fetch/XHR, `LIVE` actions) are listed in the toolbar. `persist: true` keeps profiles in tmp/profiler.sqlite3. Budgets: `budget_ms: 300`, `budgets: {"GET /posts": 120, "PostsController#show": 80}`; specs list requests over budget (`SILTH_BUDGETS=strict` fails them).
I18n: `config/locales/<locale>.yml`, `t("key", count: n, name: x)`, `l(time, "long")`.

## CLI
`silth check` type-checks the app without building it (seconds; `--spec` adds the specs): run it after each change. `silth new|serve|build|test|g|routes|db:migrate|db:rollback|db:status|db:seed|db:fresh|db:schema:dump|db:schema:load|queue:work|schedule:run|assets:build|api:docs|workflow:dump|export|key:generate|about|down|up|deploy:init|deploy|deploy:status|deploy:rollback`. Deploy: config/deploy.yml (`image`, `servers`, `domain`, `env_file`, `registry`, `workers`, `scheduler`, `volumes`), zero-downtime rollout over SSH + Docker + Caddy, `silth deploy --dry-run`. Custom: `class X < Silth::Command; command "x:y", "desc"; argument a : String; option o : Bool = false; def run : Nil; end; end`.
