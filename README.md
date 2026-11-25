<p align="center"><img src=".github/logo.svg" width="72" alt="Silth"></p>
<h1 align="center">Silth</h1>
<p align="center">A batteries-included MVC web framework for <a href="https://crystal-lang.org">Crystal</a>, with zero third-party dependencies.<br>
<a href="https://silth.dev/docs">Documentation</a> · <a href="https://github.com/silthhq/website">Website &amp; docs sources</a> · <a href="ROADMAP.md">Roadmap</a></p>

---

```crystal
Silth.routes do
  get "/", HomeController, :index
  resources "posts", PostsController
  live "/search", SearchComponent
end

class Post < ApplicationModel
  primary_key
  column title : String
  column embedding : Array(Float32)?
  belongs_to author : User
  validates title, presence: true
end

Post.search([:title, :body], "crystal").includes(:author).paginate(1)
Post.nearest(:embedding, query_vector).limit(5)
```

## What's inside

Routing · middleware · controllers · ECR templates with auto-escaping · components · **live components** (WebSocket, DOM morphing) · assets without a build step · ORM & query builder · **native drivers for PostgreSQL, MariaDB/MySQL and SQLite** · migrations, seeders, factories, pagination · pgvector & full-text search · authentication (sessions, tokens, JWT, TOTP) · policies & gates · CSRF, CSP nonces, rate limiting, encryption, signed URLs · cache (memory/file/db/Redis) · events · queues (sync/memory/db/Redis) · scheduler · mail (SMTP built in) · notifications · storage (local/S3 with SigV4) · i18n · concurrency helpers · HTTP client · channels & presence · workflows (state machines) · Stripe billing · OpenAPI docs · profiler & debug toolbar · OpenTelemetry (OTLP) · structured logging · CLI, generators & scaffolds · testing (in-process HTTP, fakes, browser tests) · dev server with live reload · static export.

## Quick start

```bash
brew install crystal                 # or https://crystal-lang.org/install
git clone https://github.com/silthhq/framework.git && cd framework
shards build silth --release && cp bin/silth /usr/local/bin/
silth new blog && cd blog && shards install
silth g scaffold Post title:string 'body:text?'
silth db:migrate && silth serve      # http://localhost:3000 · profiler: /_silth/profiler
```

Applications depend on the shard:

```yaml
dependencies:
  silth:
    github: silthhq/framework
```

## This repository

| Path | Content |
|---|---|
| [`src/`](src) | the `silth` shard (`src/silth.cr`) and the global CLI (`src/cli/main.cr`) |
| [`spec/`](spec) | framework specs |
| [`skills/`](skills) | agent skills: `silth` (building apps, shipped in every new app) and `silth-framework` (contributing) |
| [`docker/`](docker) | official Docker images (`ghcr.io/silthhq/builder`, `ghcr.io/silthhq/runtime`) |
| [`docker-compose.yml`](docker-compose.yml) | PostgreSQL + pgvector, MariaDB, MySQL 8.4, Redis, Mailpit, MinIO, Jaeger for development |

The documentation lives with the website in [silthhq/website](https://github.com/silthhq/website) (`docs/`).

## Development

```bash
docker compose up -d
crystal spec                                     # SQLite
SILTH_TEST_DATABASE_URL=postgres://silth:silth@127.0.0.1:55432/silth_test crystal spec
SILTH_TEST_DATABASE_URL=mysql://silth:silth@127.0.0.1:53306/silth_test crystal spec      # MariaDB
SILTH_TEST_DATABASE_URL=mysql://silth:silth@127.0.0.1:53307/silth_test \
  SILTH_TEST_MYSQL_ADMIN_URL=mysql://root:silth@127.0.0.1:53307/silth_test crystal spec   # MySQL 8 + auth specs
```

CI runs the same matrix on every pull request (`.github/workflows/ci.yml`). See [AGENTS.md](AGENTS.md) for the contribution rules.

## License

MIT
