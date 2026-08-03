# syntax=docker/dockerfile:1
#
# Casein production image — audit_remote.md CC-1.
#
# Two stages:
#   builder — full Elixir/Erlang toolchain, compiles deps + assets +
#             release. The erlexec port driver is built here.
#   runtime — debian slim + tmux + ERTS-bundled release. No mix, no
#             compiler, no node.
#
# Build:
#   docker build -t casein:latest .
#
# Run (operator provides env — see docs/deploy.md):
#   docker run --rm -p 4000:4000 \
#     -e PHX_SERVER=true \
#     -e PHX_HOST=cloud-1.dev \
#     -e PORT=4000 \
#     -e SECRET_KEY_BASE=<mix phx.gen.secret> \
#     -e DATABASE_URL=ecto://... \
#     -e CASEIN_API_TOKEN=<bearer> \
#     -e CASEIN_WORKSPACES_ROOT=/workspaces \
#     -v /path/to/workspaces:/workspaces \
#     casein:latest
#
# By default Casein discovers workspaces as directories under
# CASEIN_WORKSPACES_ROOT. Optional integrations (see
# docs/integrations/) supply alternative workspace sources via config.

# ---- Stage 1: build the release --------------------------------------
# Builder and runtime share the same Debian release + build date so glibc
# and friends match between the two images.
# hexpm/elixir publishes no 1.20.0 image built against OTP 29, and 29.0.4 is
# only cut for the 20260713 Debian date — so the Elixir patch and Debian date
# move with OTP here rather than independently.
ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=29.0.4
ARG DEBIAN_RELEASE=bookworm
ARG DEBIAN_DATE=20260713
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_RELEASE}-${DEBIAN_DATE}-slim"
ARG RUNNER_IMAGE="debian:${DEBIAN_RELEASE}-${DEBIAN_DATE}-slim"
ARG CASEIN_REPO_ADAPTER=postgres
ARG CASEIN_GIT_REVISION=
ARG CASEIN_RELEASE_PROFILE=devbox
ARG CASEIN_RELEASE_REPO_ADAPTER=
ARG CASEIN_RELEASE_TARGET=
ARG CASEIN_RELEASE_CHANNEL=canary
ARG CASEIN_UPDATE_MANIFEST_URL=

FROM ${BUILDER_IMAGE} AS builder
ARG CASEIN_REPO_ADAPTER
ARG CASEIN_GIT_REVISION
ARG CASEIN_RELEASE_PROFILE
ARG CASEIN_RELEASE_REPO_ADAPTER
ARG CASEIN_RELEASE_TARGET
ARG CASEIN_RELEASE_CHANNEL
ARG CASEIN_UPDATE_MANIFEST_URL

# Build deps needed by erlexec (its port is compiled here), any
# native NIFs in the dependency tree, plus Node/npm for the asset
# pipeline (CodeMirror — installed via npm in assets/).
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      build-essential \
      git \
      curl \
      ca-certificates \
      nodejs \
      npm \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod \
    CASEIN_REPO_ADAPTER=${CASEIN_REPO_ADAPTER} \
    CASEIN_GIT_REVISION=${CASEIN_GIT_REVISION} \
    CASEIN_RELEASE_PROFILE=${CASEIN_RELEASE_PROFILE} \
    CASEIN_RELEASE_REPO_ADAPTER=${CASEIN_RELEASE_REPO_ADAPTER} \
    CASEIN_RELEASE_TARGET=${CASEIN_RELEASE_TARGET} \
    CASEIN_RELEASE_CHANNEL=${CASEIN_RELEASE_CHANNEL} \
    CASEIN_UPDATE_MANIFEST_URL=${CASEIN_UPDATE_MANIFEST_URL} \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN mix local.hex --force && mix local.rebar --force

# Pull mix metadata first so dep changes invalidate cache before code.
COPY mix.exs mix.lock ./
COPY config config
# Local path dependencies must be present before deps.get/compile can resolve
# them.
COPY casein_core casein_core
COPY casein_preview_browser casein_preview_browser
RUN mix deps.get --only prod && mix deps.compile

# Application code first — esbuild reads compile-time artifacts from
# _build/prod/phoenix-colocated (Phoenix 1.8 colocated hooks), so the
# Elixir compile must run before the asset deploy.
COPY lib lib
COPY assets assets
COPY priv priv
RUN cd assets && npm install --no-audit --no-fund --no-progress
RUN cd priv/scripts && npm ci --omit=dev --no-audit --no-fund --no-progress
RUN mix compile
RUN mix assets.setup && mix assets.deploy

# rel/ overlays (env script, migrate, etc).
COPY rel rel

# Release docs — mix.exs `copy_release_docs/1` copies these into the release
# tree as a final assemble step. Without them, `mix release` aborts here.
COPY README.md README.md
COPY docs docs

RUN mix release casein

# ---- Stage 2: minimal runtime ----------------------------------------
FROM ${RUNNER_IMAGE} AS runtime

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      libstdc++6 \
      openssl \
      libncurses6 \
      locales \
      ca-certificates \
      libsqlite3-0 \
      tmux \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    MIX_ENV=prod \
    HOME=/home/casein \
    PHX_SERVER=true \
    SHELL=/bin/bash

# Run as a non-root user. The default workspace mount point is owned
# by this user so the runtime can read/write workspace contents that
# match its UID:GID (operator can override via -u or by chowning the
# bind-mounted directory).
RUN groupadd --gid 1000 casein \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash casein \
    && mkdir -p /workspaces \
    && chown -R casein:casein /workspaces

WORKDIR /app

COPY --from=builder --chown=casein:casein /app/_build/prod/rel/casein ./

USER casein

EXPOSE 4000

# Migrations are explicit, not at server boot — operator runs:
#   docker run casein:latest /app/bin/casein eval "Casein.Release.migrate()"
# (or use the rel/overlays/bin/migrate helper) before bringing up the
# server pool. This keeps zero-downtime upgrades sane: one task pod
# migrates; the server pool then rolls.
CMD ["/app/bin/casein", "start"]
