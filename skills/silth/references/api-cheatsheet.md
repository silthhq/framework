# Silth API cheat sheet

## Config & env
`Silth.config.string("app.name")`, `.int("server.port", 3000)`, `.bool`, `.array`, `.hash`, `.bind("mail", MailSettings)`. YAML supports `${VAR:-default}` and `when@production:` blocks. `Silth.env`, `Silth.production?`.

## Context / controller
params: `params["id"]`, `params["q"]?`, `params.int("page", 1)`, `params.permit(:a, from: :post)`, `params.file("avatar")`, `params.json`.
responses: `render`, `json(obj, status)`, `text`, `redirect(url, notice:)`, `redirect_back`, `head(204)`, `send_file`, `stream`, `sse`, `problem(422, "Title")`.
state: `session[...]`, `flash["notice"]`, `ctx.set_signed_cookie`, `ctx.auth_user`, `ctx.locale`.
filters: `before_action :m, only: [...]`, `after_action`, `rescue_from Klass, with: :handler`.
validation: `data = validate!(CreatePostRequest)` (FormRequest with `field title : String, min: 3`).

## ORM
CRUD: `create!`, `save`, `save!`, `update`, `destroy`, `find`, `find?`, `find_by`, `first_or_create`, `reload`, `touch`, `increment!`.
Query: `where`, `or_where`, `where_not`, `where_in`, `where_null`, `where_between`, `where_like`, `where_group { |g| … }`, `join`, `order(created_at: :desc)`, `latest`, `limit`, `offset`, `group_by`, `having`, `select`, `distinct`, `includes(:rel)`, `with_trashed`, `lock_for_update(skip_locked: true)`.
Fetch: `to_a`, `first`, `first?`, `last`, `count`, `exists?`, `pluck`, `sum/avg/min/max`, `paginate(page, per)`, `cursor_paginate`, `find_each`.
PostgreSQL: `search([:title, :body], q)`, `order_by_relevance`, `nearest(:embedding, vec, metric: :cosine)`, `select_distance`, `where_json`, `where_json_contains`.
Relations: `belongs_to x : X, optional: true`, `has_many xs : X, through: "pivot", dependent: :destroy`, `has_one`. Many-to-many: `attach_tags`, `detach_tags`, `sync_tags`.
Validations: presence, length, format, email, url, inclusion, exclusion, numericality, uniqueness (`{scope: [...]}`), confirmation, acceptance, `if:`. Custom: `def validate; errors.add("f", "msg"); end`.
Raw: `Silth::DB.query(sql, args).to_hashes`, `Silth::DB.table("x")…`, `Silth::DB.transaction { }`.

## Views
Helpers: `link_to`, `button_to(text, url, method: "delete", confirm:)`, `route(name, **params)`, `form_with`, `f.text_field/text_area/select/check_box/errors_for/submit`, `t`, `l`, `paginate`, `flash_messages`, `partial "dir/_x", local: v`, `content_for`, `yield_content`, `component`, `live`, `stylesheet_tag`, `importmap_tags`, `silth_scripts`, `csrf_meta_tags`.

## Components
`class X < Silth::Component; prop title : String; template "components/x"; end` → `<%= component X, title: "…" %>`, slot via `<%= yield_slot %>`.
Live: `class Y < Silth::LiveComponent; prop q : String = "", writable: true; action def go; …; end; end`. Directives: `silth-click`, `silth-args`, `silth-submit`, `silth-model(.debounce.300ms|.lazy)`, `silth-change`, `silth-keydown.enter`, `silth-poll`, `silth-confirm`, `data-key`. Server push: `def subscriptions; ["topic"]; end` + `Silth::Live.refresh("topic")`. Browser events: `emit("name", payload)` → `window` event `silth:name`.

## Auth & authorization
`include Silth::Auth::Authenticatable` (needs `password_digest`). `auth.attempt(email, pw, remember:)`, `auth.login(user)`, `auth.logout`, `user.create_token("cli", ["posts:read"])`, `Silth::JWT.encode/decode`, `Silth::Auth::TOTP`, `Silth::Auth.password_reset_token(user)`. Middleware aliases: `:auth`, `:guest`, `:verified`, `:signed`, `:throttle`.
Policies: `class PostPolicy < Silth::Policy; def update?(user : User, post : Post) : Bool; end; end`, `authorize! :update, post`, `can?(:update, post)`, `Silth::Gate.define("admin") { |u| … }`.

## Services
Cache: `Silth.cache.fetch(key, 10.minutes) { … }`, `lock`, `increment`.
Events: `Silth::Events.listen(E) { |e| }`, `dispatch`, `Listener(E)` classes (`queued`).
Jobs: `class J < Silth::Job; queue "q"; retries 3; def perform : Nil; end; end`, `J.new(…).dispatch(delay: 5.minutes)`, `silth queue:work`.
Schedule: `Silth.schedule { |s| s.job(J.new).daily_at("03:00") }`.
Mail: `class M < Silth::Mail; def build : Nil; to …; subject …; html render_to_string("mails/x", layout: "layouts/mail", …); end; end`, `.deliver` / `.deliver_later`.
Notifications: `class N < Silth::Notification; def via(n) : Array(Symbol); [:mail, :database]; end; end`, `user.notify(N.new)`.
Storage: `Silth.storage.put/get?/read/url/temporary_url/put_file`, disks local|s3|memory.
HTTP: `Silth::HTTPClient.new.bearer(t).retry(3).get(url).json`.
Concurrency: `Silth::Concurrency.run`, `.map(items, workers: 8)`, `.defer`, `.timeout`, `.retry`.
Realtime: `class C < Silth::Channel; topic "chat:*"; def handle_in(event, payload); broadcast(event, payload); end; end`, `Silth::Broadcast.to(topic, event, payload)`.
Workflows: `config/workflows.yml`, `Silth::Workflow.get("name").apply(model, "transition", user)`.
Billing: `include Silth::Billing::Billable`, `user.checkout(price, success_url:, cancel_url:)`, `user.subscribed?`.
Telemetry: `Silth::Telemetry.trace("name") { |span| }`, `counter`, `histogram`.
I18n: `config/locales/<locale>.yml`, `t("key", count: n, name: x)`, `l(time, "long")`.

## CLI
`silth new|serve|build|test|g|routes|db:migrate|db:rollback|db:status|db:seed|db:fresh|queue:work|schedule:run|assets:build|api:docs|workflow:dump|export|key:generate|about|down|up`. Custom: `class X < Silth::Command; command "x:y", "desc"; argument a : String; option o : Bool = false; def run : Nil; end; end`.
