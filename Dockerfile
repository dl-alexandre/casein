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
#     -e DEV_IDE_API_TOKEN=<bearer> \
#     -e MILC_DEVBOX_MANAGER_URL=http://manager.local:9000 \
#     -e DEV_IDE_WORKSPACES_ROOT=/workspaces \
#     -v /path/to/workspaces:/workspaces \
#     dev_ide:latest
#
# CC-4 decision: DevIDE ships as its own image. The milc-devbox manager
# is a separate concern, reached via MILC_DEVBOX_MANAGER_URL. Pair them
# via docker-compose / k8s if you want them colocated.

# ---- Stage 1: build the release --------------------------------------
ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.2
ARG DEBIAN_VERSION=bookworm-20241202-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# Build deps needed by erlexec (its port is compiled here) and any
# native NIFs in the dependency tree.
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      build-essential \
      git \
      curl \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN mix local.hex --force && mix local.rebar --force

# Pull mix metadata first so dep changes invalidate cache before code.
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile

# Asset toolchain — Tailwind + esbuild are downloaded by Mix tasks.
COPY assets assets
COPY priv priv
RUN mix assets.setup && mix assets.deploy

# Application code
COPY lib lib
RUN mix compile

# Optional rel/ overlays (env script, migrate, etc).
COPY rel rel

RUN mix release dev_ide

# ---- Stage 2: minimal runtime ----------------------------------------
FROM ${RUNNER_IMAGE} AS runtime

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      libstdc++6 \
      openssl \
      libncurses6 \
      locales \
      ca-certificates \
      tmux \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    MIX_ENV=prod \
    HOME=/app \
    PHX_SERVER=true

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
#   docker run dev_ide:latest /app/bin/dev_ide eval "DevIde.Release.migrate()"
# (or use the rel/overlays/bin/migrate helper) before bringing up the
# server pool. This keeps zero-downtime upgrades sane: one task pod
# migrates; the server pool then rolls.
CMD ["/app/bin/dev_ide", "start"]
