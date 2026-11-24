# silth (framework)

The Silth shard: a batteries-included MVC web framework for Crystal with zero third-party dependencies.

```yaml
# shard.yml of your application
dependencies:
  silth:
    github: silth-framework/silth
```

```crystal
require "silth"
```

- Documentation: [`../docs`](../docs) or https://silth.dev/docs
- CLI: `shards build silth` → `bin/silth`
- Specs: `crystal spec` (set `SILTH_TEST_DATABASE_URL` to run on PostgreSQL or MariaDB)

Module map: see [`../skills/silth-framework/SKILL.md`](../skills/silth-framework/SKILL.md).
