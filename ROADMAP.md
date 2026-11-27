# Roadmap

## Stage 1: the framework ✅

Everything listed in the README: HTTP stack, ORM with native drivers, live components, services, observability, tooling, website, documentation and agent skills.

Iterations shipped after the first release of the stage:

- [x] Binary prepared statements for MySQL (per-connection LRU cache, interpolation fallback) and RSA full auth for `caching_sha2_password` / `sha256_password` without TLS
- [x] Reversible `change` migrations and schema dumps (`db/schema.cr`)
- [x] Polymorphic relations, counter caches, optimistic locking
- [x] Named slots for components, live component file uploads, nested live components
- [x] Redis/PostgreSQL `LISTEN/NOTIFY` pub/sub adapter configured from YAML for multi-node live components
- [x] Job batches, unique jobs and rate-limited queues
- [x] Mail previews in the profiler, markdown mail templates
- [x] Log, cache and session drivers for PostgreSQL `UNLOGGED` tables
- [x] Official Docker images and a `silth deploy` preset

## Consolidation ✅

- [x] One repository per project under the `silthhq` organization: `framework` (this one) and `website` (silth.dev and the documentation). Closed projects get their own private repositories.
- [x] GitHub Actions: specs on SQLite, PostgreSQL (pgvector), MariaDB 11 and MySQL 8.4 with Redis; a generated app scaffolded, migrated, rolled back and tested end to end; the website exported as in production
- [x] Docker images built in CI, an app generated inside the builder and its runtime image answering `/up`; multi-arch images (`amd64`, `arm64`) published to `ghcr.io/silthhq/builder` and `ghcr.io/silthhq/runtime`
- [x] Profiler: request timeline (phases, action, templates, components, queries, HTTP calls, logs), toolbar with hover details and links opening in a new tab, folding into a corner icon, dashboard with a sidebar, translations (missing keys) and logs panels
- [x] Identity: a new mark (a mask with two hollow eyes), flat theme without gradients or glows for the internal pages, the app template and the website
- [x] MariaDB `ed25519` / `parsec` accounts: a clear error naming the plugin and a documented workaround (`mysql_native_password`), support planned below

## Stage 1.x: next iterations ✅

Each item shipped with specs, the cheat sheet and the docs page.

### 1. First release

- [x] Check the CI with Crystal 1.22: green on GitHub; a local run on Crystal 1.22 with SQLite, PostgreSQL 16, MariaDB 10.11 and 11.8 and MySQL 8.4 found two bugs, fixed (a `return` inside `DB#transaction` left the transaction open; the lazy `CREATE TABLE` of the batch store committed the specs' transactions on MySQL)
- [x] `v0.1.0` prepared: `CHANGELOG.md` with the compatibility policy (semver, deprecations kept one minor version, `Silth.deprecated` and `SILTH_DEPRECATIONS=raise`), images tagged `X.Y.Z`, `X.Y`, `latest` (and `edge` from `main`), new apps on the CLI's release line (`~> 0.1.0`, `--edge` for `main`). The tag itself is pushed by hand after the merge
- [x] Release workflow on tags (`.github/workflows/release.yml`): checks the version everywhere, static Linux `x86_64`/`aarch64` and macOS `arm64`/`x86_64` CLI binaries, `SHA256SUMS`, GitHub release from the changelog, then installs it with `scripts/install.sh`, served at silth.dev/install.sh
- [x] Versioned documentation on the website: `docs/` follows `main` (`/docs/edge`), `versions/X.Y/` are frozen by `bin/cli docs:release X.Y`, the newest release is served at `/docs`

### 2. Database

- [x] MariaDB `ed25519` authentication with an in-house Ed25519 (RFC 8032 vectors, checked against OpenSSL and real MariaDB accounts), then `parsec` (PBKDF2 key, MariaDB 11.6+)
- [x] Read replicas: `replicas:` per connection, reads routed to the replicas in turn, writes and transactions to the primary, sticky reads after a write in the same request or job, and for `sticky_for` seconds through a cookie; an unreachable replica is rested
- [x] Query log linked to the line of application code that ran each query; repeats from one line reported as possible N+1
- [x] `silth db:console`: password through the environment, `--connection`, `--replica`, `--print`

### 3. Profiler and developer experience

- [x] Sub-requests in the toolbar: fetch/XHR calls and live component actions, each with its own profile
- [x] Editor links: file:line in the debug page, the timeline, the queries and exceptions panels open in VS Code, Cursor, Zed, JetBrains IDEs… or a URL template (`profiler.editor`)
- [x] Optional persistence of profiles (`tmp/profiler.sqlite3`) so they survive a rebuild in `silth serve`
- [x] Performance budget per route or handler (`profiler.budget_ms`, `profiler.budgets`), flagged in the toolbar, the dashboard and the test output

### 4. Front end

- [x] Component previews page in the dashboard (`Silth::ComponentPreview`, like mail previews): widths, editable props, slots, usage snippet; the base for a future UI kit
- [x] Accessible, unstyled-by-default components shipped with the template (`UI::Dialog`, `UI::Dropdown`, `UI::Tabs`, `UI::Toast`) working with live components, with previews

## 0.2: performance and business applications

Driven by a benchmark against Loco (Rust) and by porting an ERP from Loco to Silth.

- [x] Fair connection pool (hand-over to the oldest waiter after 1 ms of waiting): p99 divided by 5 to 6 under contention
- [x] No transaction around a save without hooks; prepared statements cached per PostgreSQL connection; models written to JSON directly (twice as fast)
- [x] `server.workers` (supervised processes on one port), `silth check`, strict generator types
- [x] Money and dates: `Decimal` (exact, scale kept, `"12.50"` in JSON) and `Date` end to end; JSON time precision (`auto` = chrono's format)
- [x] Argon2id password hashing (pure Crystal) next to bcrypt, re-hash on login; JWT HS384/HS512; multipart HTTP client
- [ ] Crystal execution contexts (multi-threaded fibers) once stable, instead of worker processes
- [ ] Incremental type checking: watch mode for `silth check` keeping the compiler warm

## Stage 2: ecosystem

The framework stays MIT and never depends on a paid service. Paid services plug into public, documented interfaces that are part of the framework: OpenTelemetry export, `Silth::Instrument` events, `config/deploy.yml`.

| Project | Repository | Licence | Inspired by | Idea |
|---|---|---|---|---|
| `admin` | `silthhq/admin` (public) | MIT | Laravel Nova | admin panel generated from models (resources, filters, actions, metrics) built with live components |
| `metrics` | private | proprietary, paid | Laravel Nightwatch | hosted OpenTelemetry backend tuned for Silth: requests, queries, jobs, exceptions, alerting; fed by the framework's OTLP exporter |
| `deploy` | private | proprietary, paid | Laravel Forge | server provisioning, multi-server releases, TLS, secrets, workers and scheduler supervision, a dashboard; the open `silth deploy` preset (one server over SSH) stays in the framework |

Proposed order: `admin` first (it stresses live components and the ORM, and feeds the framework), then `metrics` (the OTLP export already exists), then `deploy`.
