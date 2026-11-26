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

### Fixed before the release

- `DB#transaction` commits when the block returns early (`return`, `break`); it used to hand the connection back to the pool with the transaction still open.
- A failing `ROLLBACK TO SAVEPOINT` no longer hides the error raised by the block.
- `Silth::Testing.setup` creates the queue, batch and cache tables before wrapping examples in transactions: on MySQL the lazy `CREATE TABLE` committed them.
