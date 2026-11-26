# Changelog

All notable changes to Silth. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the versions follow [semantic versioning](https://semver.org) with the compatibility policy below.

## Compatibility policy

- **Versions** are `MAJOR.MINOR.PATCH`. Until 1.0, a minor version (`0.1` → `0.2`) may change public APIs, a patch version (`0.1.0` → `0.1.1`) only fixes bugs. From 1.0, breaking changes wait for the next major version.
- **Deprecations** are kept for one minor version: an API deprecated in `0.2` still works in `0.2`, warns, and is removed in `0.3`. Methods carry Crystal's `@[Deprecated]` annotation (a compile time warning); configuration keys and behaviors log a `silth.deprecation` warning once per process (`SILTH_DEPRECATIONS=raise` turns them into errors, handy in CI).
- **Public API** means what the documentation at silth.dev describes: classes, methods, macros, configuration keys, CLI commands and generated files. Anything marked `:nodoc:` or living under an `Internal` namespace can change in any release.
- **Supported versions**: Crystal 1.22 and later, PostgreSQL 13+, MariaDB 10.6+, MySQL 8.0+, SQLite 3.35+. The latest minor version gets bug fixes; security fixes also go to the previous one.
- **Upgrading**: read the "Upgrading" notes of each version below, update `shard.yml` (`version: ~> 0.2.0`), run `shards update silth`, then `silth test` with `SILTH_DEPRECATIONS=raise`.

Each release publishes the `silth` CLI for Linux (`amd64`, `arm64`) and macOS with checksums, the Docker images `ghcr.io/silthhq/builder` and `ghcr.io/silthhq/runtime` tagged `X.Y.Z` and `X.Y`, and its documentation under `silth.dev/docs/X.Y/`.

## [Unreleased]

## [0.1.0]

The first release.

### Framework

- HTTP stack: routing with constraints and named routes, middleware, controllers with filters, typed params and form requests, sessions, cookies, flash, CSRF, CSP nonces, rate limiting, signed URLs, encryption.
- Views: ECR templates with auto-escaping, layouts, partials, helpers, a form builder, components with props and named slots.
- Live components over WebSocket with DOM morphing, nested live components, file uploads, and a Redis or PostgreSQL `LISTEN/NOTIFY` pub/sub to run them on several nodes.
- Assets without a build step: import maps, fingerprinting, live reload in development.
- Database: native drivers for PostgreSQL (wire protocol v3), MariaDB/MySQL (protocol 4.1, binary prepared statements, `caching_sha2_password` and `sha256_password` with RSA or TLS) and SQLite; pools, transactions with savepoints, a query builder, migrations (reversible `change`), schema dumps (`db/schema.cr`), seeders, factories, pagination, pgvector and full-text search.
- ORM: typed models, validations, scopes, dirty tracking, soft deletes, relations (polymorphic included), eager loading, counter caches, optimistic locking.
- Services: cache (memory, file, database, Redis, PostgreSQL `UNLOGGED`), events, queues (sync, memory, database, Redis) with batches, unique and rate-limited jobs, a scheduler, mail (SMTP, Markdown templates), notifications, storage (local, S3 with SigV4), i18n, an HTTP client with fakes, channels and presence, workflows (state machines), Stripe billing, OpenAPI documents.
- Security: authentication (sessions, tokens, JWT, TOTP), policies and gates.
- Observability: a profiler with a request timeline and a debug toolbar, mail previews, structured logging, OpenTelemetry export (OTLP).
- Tooling: the `silth` CLI, generators and scaffolds, a development server with live reload, in-process HTTP testing and browser tests, a static site export, `silth deploy` (Docker over SSH), official Docker images, agent skills shipped with every app.

### Database

- Read replicas: `replicas:` per connection; reads go to the replicas in turn, writes and transactions to the primary, reads after a write stay on the primary for the rest of the request or job and, through a cookie, for `sticky_for` seconds; `DB.on_primary { }`; an unreachable replica is skipped for 10 seconds.
- `silth db:console` passes the password through the environment instead of the command line, follows the URL's TLS settings, prefers the `mariadb` client, and takes `--connection`, `--replica` and `--print`.
- MariaDB `ed25519` and `parsec` (11.6+) authentication, with an in-house Ed25519 signature: `ed25519` derives its key from SHA-512 of the password, which OpenSSL's EVP API cannot take.

### Profiler and developer experience

- Each query is traced back to the line of application code that ran it (queries panel, timeline, toolbar); the same statement from the same line several times is reported as a possible N+1 with that line. `profiler.query_sources` turns it off.
- Sub-requests in the toolbar: `fetch`/XHR calls answered with an `X-Silth-Profile` header and live component actions (now profiled as `LIVE` requests), each linking to its own profile.
- Profiles can be saved to `tmp/profiler.sqlite3` (`profiler.persist`, on in development for new apps) so they survive the restarts of `silth serve`.
- Performance budgets per route or handler (`profiler.budget_ms`, `profiler.budgets`): flagged in the toolbar and the dashboard, listed at the end of the test run, or failing the spec with `budget_strict` / `SILTH_BUDGETS=strict`.
- Editor links: `file:line` in the debug page, the timeline, the queries and exceptions panels open in VS Code, Cursor, Zed, JetBrains IDEs, Sublime Text… or a URL template (`profiler.editor`, `SILTH_EDITOR`, `profiler.editor_root` for containers).

### Front end

- Component previews: `Silth::ComponentPreview` scenarios (like mail previews) listed in the profiler's Components section: each one in a frame with the app's stylesheets at several widths, its props (scalar ones editable on the page), its slots, the template code that renders it and its HTML. `Component#with_slots`, `#fill_slot`, `#prop_specs`, `#preview_usage`. `silth g component` and `silth g live` write a preview.
- New apps ship accessible UI components, unstyled by default (`data-ui` hooks, looks in `assets/ui.css`): `UI::Dialog` (native `<dialog>`, server-driven `open` and `close_action` in live components), `UI::Dropdown` (menu button), `UI::Tabs`, `UI::Toast` and `UI::Toaster` (live regions, `emit "toast"` from live actions); keyboard behavior in `assets/js/ui.js` following the WAI-ARIA practices, previews included.
- `silth-keep="attr …"`: attributes the browser owns (an open dialog, the selected tab) survive live component re-renders.

### Fixed before the release

- `DB#transaction` commits when the block returns early (`return`, `break`); it used to hand the connection back to the pool with the transaction still open.
- A failing `ROLLBACK TO SAVEPOINT` no longer hides the error raised by the block.
- `Silth::Testing.setup` creates the queue, batch and cache tables before wrapping examples in transactions: on MySQL the lazy `CREATE TABLE` committed them.
