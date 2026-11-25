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

## Stage 1.x: next iterations

Proposed order. Each item ships with specs, the cheat sheet and the docs page, like before.

### 1. First release

- [ ] Check the new CI on GitHub with Crystal 1.22 and fix what the local harness (Crystal 1.11 + shims) could not catch
- [ ] Tag `v0.1.0`: `CHANGELOG.md`, compatibility policy (semver, deprecations kept one minor version), images tagged by version
- [ ] Release workflow on tags: prebuilt `silth` CLI binaries (Linux `amd64`/`arm64`, macOS), checksums, install script on silth.dev
- [ ] Versioned documentation on the website (`/docs/0.1/…`), the latest version by default

### 2. Database

- [ ] MariaDB `ed25519` authentication. Needs an in-house Ed25519 signature: MariaDB derives the key from `SHA-512(password)` instead of a 32-byte seed, so OpenSSL's EVP API cannot be used as is. `parsec` after that.
- [ ] Read replicas: `replicas:` per connection, reads routed to a replica, writes and transactions to the primary, sticky reads after a write in the same request
- [ ] Query log in the profiler linked to the line of application code that ran each query (N+1 hunting)
- [ ] `silth db:console` (psql, mysql or sqlite3 with the configured URL)

### 3. Profiler and developer experience

- [ ] Sub-requests in the toolbar: fetch/XHR calls and live component actions of the page, each with its own profile (like Symfony's AJAX panel)
- [ ] Editor links: file:line in the debug page, the timeline and the queries panel open in VS Code, Zed or a custom URL (`profiler.editor`)
- [ ] Optional persistence of profiles (SQLite file under `tmp/`) so they survive a rebuild in `silth serve`
- [ ] Performance budget per route (`profiler.budget_ms`), flagged in the toolbar and in test output

### 4. Front end

- [ ] Component previews page in the dashboard (props and slots declared in a new `Silth::ComponentPreview`, like mail previews), the base for a future UI kit
- [ ] A small set of accessible, unstyled-by-default components shipped with the template (dialog, dropdown, tabs, toast) on top of live components

## Stage 2: ecosystem

The framework stays MIT and never depends on a paid service. Paid services plug into public, documented interfaces that are part of the framework: OpenTelemetry export, `Silth::Instrument` events, `config/deploy.yml`.

| Project | Repository | Licence | Inspired by | Idea |
|---|---|---|---|---|
| `admin` | `silthhq/admin` (public) | MIT | Laravel Nova | admin panel generated from models (resources, filters, actions, metrics) built with live components |
| `metrics` | private | proprietary, paid | Laravel Nightwatch | hosted OpenTelemetry backend tuned for Silth: requests, queries, jobs, exceptions, alerting; fed by the framework's OTLP exporter |
| `deploy` | private | proprietary, paid | Laravel Forge | server provisioning, multi-server releases, TLS, secrets, workers and scheduler supervision, a dashboard; the open `silth deploy` preset (one server over SSH) stays in the framework |

Proposed order: `admin` first (it stresses live components and the ORM, and feeds the framework), then `metrics` (the OTLP export already exists), then `deploy`.
