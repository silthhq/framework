# Roadmap

## Stage 1 — the framework ✅

Everything listed in the README: HTTP stack, ORM with native drivers, live components, services, observability, tooling, website, documentation and agent skills.

Next iterations of stage 1:

- [x] Binary prepared statements for MySQL (per-connection LRU cache, interpolation fallback) and RSA full auth for `caching_sha2_password` / `sha256_password` without TLS
- [x] Reversible `change` migrations and schema dumps (`db/schema.cr`)
- [x] Polymorphic relations, counter caches, optimistic locking
- [x] Named slots for components, live component file uploads, nested live components
- [x] Redis/PostgreSQL `LISTEN/NOTIFY` pub/sub adapter configured from YAML for multi-node live components
- [x] Job batches, unique jobs and rate-limited queues
- [x] Mail previews in the profiler, markdown mail templates
- [x] Log, cache and session drivers for PostgreSQL `UNLOGGED` tables
- [ ] Official Docker images and a `silth deploy` preset

## Stage 2 — ecosystem

| Project | Inspired by | Idea |
|---|---|---|
| `deploy/` | Laravel Forge | provision servers, zero-downtime releases of the single binary, TLS, workers and scheduler supervision |
| `metrics/` | Laravel Nightwatch | hosted OpenTelemetry backend tuned for Silth: requests, queries, jobs, exceptions, alerting |
| `admin/` | Laravel Nova | admin panel generated from models (resources, filters, actions, metrics) built with live components |
