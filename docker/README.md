# Official Docker images

| Image | Dockerfile | Content |
|---|---|---|
| `ghcr.io/silthhq/builder:<crystal>` | `builder.Dockerfile` | Crystal (Alpine, static linking), SQLite static library, the `silth` CLI |
| `ghcr.io/silthhq/runtime:<alpine>` | `runtime.Dockerfile` | Alpine, CA certificates, time zones, `app` user, `HEALTHCHECK` on `/up` |

Both are published for `linux/amd64` and `linux/arm64` by `.github/workflows/docker-images.yml` (on `main`, on `v*` tags, or by hand), also as `:latest` and as the release tag.

The `Dockerfile` of every new app builds with the first and runs on the second:

```dockerfile
ARG SILTH_BUILDER=ghcr.io/silthhq/builder:1.22
ARG SILTH_RUNTIME=ghcr.io/silthhq/runtime:3.20
FROM ${SILTH_BUILDER} AS build
…
FROM ${SILTH_RUNTIME}
```

Build them locally from the repository root:

```bash
docker build -f docker/builder.Dockerfile -t ghcr.io/silthhq/builder:1.22 .
docker build -f docker/runtime.Dockerfile -t ghcr.io/silthhq/runtime:3.20 docker
```
