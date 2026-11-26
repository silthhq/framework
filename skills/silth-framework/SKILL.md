---
name: silth-framework
description: Work on the Silth framework itself (silthhq/framework) — adding modules, fixing drivers, macros, the CLI, generators or the Docker images. Use when editing files under src/silth of the framework repository or when the user asks to extend Silth.
---

# Contributing to Silth

## Layout

```
src/silth.cr            requires every module (order matters)
src/silth/<module>.cr   one file per module (cache, queue, mailer, live, …)
src/silth/db/           pool, dialects, query builder, schema, migrations, schema dump, drivers/{postgres,mysql,sqlite}
                        (drivers/mysql/: codec.cr = text/binary value encoding, rsa.cr = RSA-OAEP auth)
src/silth/orm/          Model macros, typed Query(T), casting
src/silth/view/         ECR processor (run macro), helpers, form builder
src/silth/cli/          Command base, built-in commands
src/silth/generators/   generators + templates/app (embedded at compile time by embed.cr)
src/silth/assets/       silth.js (client runtime), livereload.js, internal.css
src/cli/main.cr         global `silth` binary
spec/                   framework specs (fixtures in spec/fixtures)
skills/                 agent skills (silth = app development, silth-framework = this one)
docker/                 official images (builder, runtime) published by .github/workflows/docker-images.yml
```

Documentation: silthhq/website, `docs/` (Markdown + `_nav.yml`, also served as llms.txt).

## Commands

```bash
crystal spec                                              # SQLite in memory
SILTH_TEST_DATABASE_URL=postgres://silth:silth@127.0.0.1:55432/silth_test crystal spec
SILTH_TEST_DATABASE_URL=mysql://silth:silth@127.0.0.1:53306/silth_test crystal spec
SILTH_TEST_DATABASE_URL=mysql://silth:silth@127.0.0.1:53307/silth_test SILTH_TEST_MYSQL_ADMIN_URL=mysql://root:silth@127.0.0.1:53307/silth_test crystal spec spec/mysql_spec.cr
docker compose up -d                                      # pgvector + MariaDB + MySQL 8.4 + Redis + Mailpit + MinIO + Jaeger
shards build silth                                        # global CLI → bin/silth
bin/silth new /tmp/demo --path-to-silth=$PWD              # end-to-end check of templates
```

After editing `templates/app` or `skills/silth`, run `scripts/sync-skills` (copies the skill into the template) and rebuild `bin/silth` (templates are embedded at compile time).

## Releasing

1. Move the `[Unreleased]` entries of `CHANGELOG.md` under `## [X.Y.Z]`, bump `version:` in `shard.yml` and `Silth::VERSION` (`spec/release_spec.cr` checks they agree).
2. Merge, then `git tag -a vX.Y.Z -m "Silth X.Y.Z" && git push origin vX.Y.Z`.
3. `.github/workflows/release.yml` builds the CLI (Linux static amd64/arm64, macOS), publishes it with `SHA256SUMS` and checks `scripts/install.sh` against it; `docker-images.yml` tags the images `X.Y.Z`, `X.Y` and `latest` (`edge` follows `main`).
4. Freeze the docs in silthhq/website: `bin/cli docs:release X.Y` copies `docs/` to `versions/X.Y/`.

Deprecations last one minor version: `@[Deprecated("…")]` on methods, `Silth.deprecated(...)` for config keys and behaviors.

## Rules

- **Zero third-party shards.** Only Crystal's stdlib and system C libraries (libsqlite3, OpenSSL).
- Keep public APIs readable; document every public class with a usage example in its doc comment.
- Every feature gets: a spec, a docs page section (`docs/…`), and an entry in the skill cheat sheet when user facing.

## Crystal pitfalls already met (avoid regressions)

- Inside `module Silth`, `Channel`, `Socket` resolve to `Silth::Channel`/`Silth::Socket`: use `::Channel(...)`, `::Socket::IPAddress`.
- `out` is a keyword; `finalize` is the GC finalizer; `protected` cannot be a variable name.
- Generic subclasses (`ORM::Query(T) < QueryBuilder`) break inline ivar initializers that use union aliases: initialize ivars in `initialize`.
- `@type` inside a def-body macro is the instantiated type: registries use `{% for t in @type.all_subclasses %}` inside methods.
- Macro tricks used: `line = __LINE__` default args to name generated methods, `@type.methods.select(&.name.starts_with?("__validation_"))` to collect them, annotations on ivars (`@[Silth::Model::Column(...)]`) read through `@type.instance_vars`.
- `{%` starts a macro: write `{ %w(...) }` with a space.
- `Time.monotonic` is deprecated: use `Time.instant`.
- InnoDB FULLTEXT indexes only see committed rows.
- Headers must be set before the body: use `ctx.before_send` / `ctx.filter_body`.
- The stdlib already binds some libcrypto symbols (`BIO_free`…): a second `fun` for the same symbol with another signature does not compile. Bind only what the stdlib lacks (see `drivers/mysql/rsa.cr`).
- MySQL prepared statements: `HANDLER`, `LOCK TABLES`… cannot be prepared (error 1295) and go through interpolation; MySQL 8 re-prepares statements internally when a parameter type changes, which also bumps `Com_stmt_prepare` (subtract `Com_stmt_reprepare` in specs).
