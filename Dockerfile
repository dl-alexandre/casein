# syntax=docker/dockerfile:1
#
# DevIDE production image — audit_remote.md CC-1.
#
# Two stages:
#   builder — full Elixir/Erlang toolchain, compiles deps + assets +
#             release. The erlexec port driver is built here.
#   runtime — debian slim + tmux + ERTS-bundled release. No mix, no
#             compiler, no node.
#
# Build:
#   docker build -t dev_ide:latest .
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
#     dev_ide:latest
#
# By default DevIDE discovers workspaces as directories under
# CASEIN_WORKSPACES_ROOT. Optional integrations (see
# docs/integrations/) supply alternative workspace sources via config.

# ---- Stage 1: build the release --------------------------------------
# Builder and runtime share the same Debian release + build date so glibc
# and friends match between the two images.
ARG ELIXIR_VERSION=1.20.0
ARG OTP_VERSION=28.5
ARG DEBIAN_RELEASE=bookworm
ARG DEBIAN_DATE=20260610
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_RELEASE}-${DEBIAN_DATE}-slim"
ARG RUNNER_IMAGE="debian:${DEBIAN_RELEASE}-${DEBIAN_DATE}-slim"
ARG CASEIN_REPO_ADAPTER=postgres
ARG DEVIDE_GIT_REVISION=
ARG DEVIDE_RELEASE_PROFILE=devbox
ARG DEVIDE_RELEASE_REPO_ADAPTER=
ARG DEVIDE_RELEASE_TARGET=
ARG DEVIDE_RELEASE_CHANNEL=canary
ARG DEVIDE_UPDATE_MANIFEST_URL=

FROM ${BUILDER_IMAGE} AS builder
ARG CASEIN_REPO_ADAPTER
ARG DEVIDE_GIT_REVISION
ARG DEVIDE_RELEASE_PROFILE
ARG DEVIDE_RELEASE_REPO_ADAPTER
ARG DEVIDE_RELEASE_TARGET
ARG DEVIDE_RELEASE_CHANNEL
ARG DEVIDE_UPDATE_MANIFEST_URL

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
    DEVIDE_GIT_REVISION=${DEVIDE_GIT_REVISION} \
    DEVIDE_RELEASE_PROFILE=${DEVIDE_RELEASE_PROFILE} \
    DEVIDE_RELEASE_REPO_ADAPTER=${DEVIDE_RELEASE_REPO_ADAPTER} \
    DEVIDE_RELEASE_TARGET=${DEVIDE_RELEASE_TARGET} \
    DEVIDE_RELEASE_CHANNEL=${DEVIDE_RELEASE_CHANNEL} \
    DEVIDE_UPDATE_MANIFEST_URL=${DEVIDE_UPDATE_MANIFEST_URL} \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN mix local.hex --force && mix local.rebar --force

# Pull mix metadata first so dep changes invalidate cache before code.
COPY mix.exs mix.lock ./
COPY config config
# Local path dependencies must be present before deps.get/compile can resolve
# them.
COPY dev_ide_core dev_ide_core
COPY dev_ide_preview_browser dev_ide_preview_browser
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
    HOME=/home/dev_ide \
    PHX_SERVER=true \
    SHELL=/bin/bash

# Run as a non-root user. The default workspace mount point is owned
# by this user so the runtime can read/write workspace contents that
# match its UID:GID (operator can override via -u or by chowning the
# bind-mounted directory).
RUN groupadd --gid 1000 dev_ide \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash dev_ide \
    && mkdir -p /workspaces \
    && chown -R dev_ide:dev_ide /workspaces

WORKDIR /app

COPY --from=builder --chown=dev_ide:dev_ide /app/_build/prod/rel/dev_ide ./

USER dev_ide

EXPOSE 4000

# Migrations are explicit, not at server boot — operator runs:
#   docker run dev_ide:latest /app/bin/casein eval "DevIDE.Release.migrate()"
# (or use the rel/overlays/bin/migrate helper) before bringing up the
# server pool. This keeps zero-downtime upgrades sane: one task pod
# migrates; the server pool then rolls.
CMD ["/app/bin/casein", "start"]
