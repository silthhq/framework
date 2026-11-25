# Silth monorepo — guide for AI coding agents

Silth is a Crystal web framework with **zero third-party shards**. This repository holds the framework, the website, the documentation and the agent skills. Detailed contributor notes (layout, commands, known Crystal pitfalls): [`skills/silth-framework/SKILL.md`](skills/silth-framework/SKILL.md).

## Quick commands

```bash
cd framework && crystal spec                     # framework specs (SQLite)
docker compose up -d                             # PostgreSQL/pgvector :55432, MariaDB :53306, MySQL 8.4 :53307, Redis, Mailpit, MinIO, Jaeger
cd framework && shards build silth               # global CLI → framework/bin/silth
cd website && ../framework/bin/silth serve       # website + docs with live reload
bin/sync-skills                                  # copy skills/silth into the app template
```

## Rules

1. Never add a shard dependency. Use Crystal's stdlib (and system libsqlite3/OpenSSL).
2. A change to a public API updates: the spec, the doc page in `docs/`, and `skills/silth/references/api-cheatsheet.md`.
3. Run specs on SQLite, and on PostgreSQL + MariaDB for anything touching `db/` or `orm/`.
4. Templates in `framework/src/silth/generators/templates/app` are embedded at compile time: rebuild `bin/silth` and try `bin/silth new /tmp/x --path-to-silth=$PWD/framework`.
5. Keep code readable: small methods, doc comments with examples, explicit names.
