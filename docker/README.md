# Official Docker images

| Image | Dockerfile | Content |
|---|---|---|
| `ghcr.io/silthhq/builder` | `builder.Dockerfile` | Crystal (Alpine, static linking), SQLite static library, the `silth` CLI |
| `ghcr.io/silthhq/runtime` | `runtime.Dockerfile` | Alpine, CA certificates, time zones, `app` user, `HEALTHCHECK` on `/up` |

Both are published for `linux/amd64` and `linux/arm64` by `.github/workflows/docker-images.yml`:

| Tag | Published from | Example |
|---|---|---|
| `X.Y.Z` | the release tag `vX.Y.Z` | `builder:0.1.0` |
| `X.Y` | the latest release of a line | `builder:0.1` |
| `latest` | the latest release | `builder:latest` |
| Crystal / Alpine version | the latest release | `builder:1.22`, `runtime:3.24` |
| `edge` | every push to `main` | `builder:edge` |

Pre-releases (`v0.2.0-rc.1`) only get their own tag. The `Dockerfile` of every new app builds with the first image and runs on the second, on the release line of the CLI that generated it (`silth new --edge` uses `edge`):

```dockerfile
ARG SILTH_BUILDER=ghcr.io/silthhq/builder:0.1
ARG SILTH_RUNTIME=ghcr.io/silthhq/runtime:0.1
FROM ${SILTH_BUILDER} AS build
…
FROM ${SILTH_RUNTIME}
```

Build them locally from the repository root:

```bash
docker build -f docker/builder.Dockerfile -t ghcr.io/silthhq/builder:dev .
docker build -f docker/runtime.Dockerfile -t ghcr.io/silthhq/runtime:dev docker
```
