# Official Silth build image: Crystal (Alpine, static linking) with the libraries
# Silth apps link against, plus the `silth` CLI.
#
#   docker build -f docker/builder.Dockerfile -t silth-builder .     (context: repository root)
#
# Used as the first stage of the Dockerfile `silth new` generates.
ARG CRYSTAL_VERSION=1.22
FROM crystallang/crystal:${CRYSTAL_VERSION}-alpine

RUN apk add --no-cache sqlite-dev sqlite-static git

COPY framework /opt/silth/framework
RUN cd /opt/silth/framework \
 && shards build silth --release --static --no-debug \
 && install -m 755 bin/silth /usr/local/bin/silth \
 && rm -rf /opt/silth/framework/bin /root/.cache \
 && silth version

WORKDIR /app
