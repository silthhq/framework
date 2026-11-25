# Silth framework: guide for AI coding agents

Silth is a Crystal web framework with **zero third-party shards**. This repository holds the shard, the global `silth` CLI, the app generator templates, the official Docker images and the agent skills. The documentation lives in a separate repository, [silthhq/website](https://github.com/silthhq/website) (`docs/`). Detailed contributor notes (layout, commands, known Crystal pitfalls): [`skills/silth-framework/SKILL.md`](skills/silth-framework/SKILL.md).

## Quick commands

```bash
crystal spec                                     # framework specs (SQLite)
docker compose up -d                             # PostgreSQL/pgvector :55432, MariaDB :53306, MySQL 8.4 :53307, Redis, Mailpit, MinIO, Jaeger
shards build silth                               # global CLI → bin/silth
scripts/sync-skills                              # copy skills/silth into the app template
```

## Rules

1. Never add a shard dependency. Use Crystal's stdlib (and system libsqlite3/OpenSSL).
2. A change to a public API updates: the spec, `skills/silth/references/api-cheatsheet.md`, and the doc page in silthhq/website (`docs/`, separate pull request).
3. Run specs on SQLite, and on PostgreSQL + MariaDB for anything touching `db/` or `orm/` (CI runs all of them plus MySQL 8).
4. Templates in `src/silth/generators/templates/app` are embedded at compile time: rebuild `bin/silth` and try `bin/silth new /tmp/x --path-to-silth=$PWD`.
5. Keep code readable: small methods, doc comments with examples, explicit names.
