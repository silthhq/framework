---
name: silth-framework
description: Work on the Silth framework itself (the monorepo with framework/, website/, docs/, skills/) — adding modules, fixing drivers, macros, the CLI, generators, docs or the website. Use when editing files under framework/src/silth or when the user asks to extend Silth.
---

# Contributing to Silth

## Layout

```
framework/                the `silth` shard
  src/silth.cr            requires every module (order matters)
  src/silth/<module>.cr   one file per module (cache, queue, mailer, live, …)
  src/silth/db/           pool, dialects, query builder, schema, migrations, drivers/{postgres,mysql,sqlite}
  src/silth/orm/          Model macros, typed Query(T), casting
  src/silth/view/         ECR processor (run macro), helpers, form builder
  src/silth/cli/          Command base, built-in commands
  src/silth/generators/   generators + templates/app (embedded at compile time by embed.cr)
  src/silth/assets/       silth.js (client runtime), livereload.js, internal.css
  src/cli/main.cr         global `silth` binary
  spec/                   framework specs (fixtures in spec/fixtures)
website/                  silth.dev, a Silth app (dogfooding) reading ../docs
docs/                     Markdown docs + _nav.yml (source of the website and llms.txt)
skills/                   agent skills (silth = app development, silth-framework = this one)
```

## Commands

```bash
cd framework
crystal spec                                              # SQLite in memory
SILTH_TEST_DATABASE_URL=postgres://silth:silth@127.0.0.1:55432/silth_test crystal spec
SILTH_TEST_DATABASE_URL=mysql://silth:silth@127.0.0.1:53306/silth_test crystal spec
docker compose -f ../docker-compose.yml up -d             # pgvector + MariaDB + Redis + Mailpit + MinIO + Jaeger
shards build silth                                        # global CLI → bin/silth
bin/silth new /tmp/demo --path-to-silth=$PWD              # end-to-end check of templates
cd ../website && ../framework/bin/silth export -o dist    # static site
```

After editing `templates/app` or `skills/silth`, run `bin/sync-skills` (copies the skill into the template) and rebuild `bin/silth` (templates are embedded at compile time).

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
