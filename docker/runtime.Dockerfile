# Official Silth runtime image: a small Alpine base for the static binaries of a
# Silth app (CA certificates, time zones, an unprivileged `app` user, a health
# check on GET /up).
#
#   docker build -f docker/runtime.Dockerfile -t ghcr.io/silthhq/runtime:dev docker
ARG ALPINE_VERSION=3.24
FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache ca-certificates tzdata \
 && adduser -D -h /app app

WORKDIR /app
USER app
ENV SILTH_ENV=production PORT=3000
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${PORT}/up" > /dev/null || exit 1
