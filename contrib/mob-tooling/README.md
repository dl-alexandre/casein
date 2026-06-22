# contrib/mob-tooling — STAGED, NOT PART OF dev_ide

This directory holds dev tooling for the **Mob** BEAM-on-device framework
(`mob_ble` / `mob_mesh` / MeshX). **It is not dev_ide code and is not compiled.**

- It lives under `contrib/` precisely because that path is **outside
  `elixirc_paths`** (`mix.exs` compiles only `lib/` and `test/support`), so the
  `.ex` files here never reach `mix compile` and cannot break the dev_ide build
  or deploy.
- The `lib/`, `bin/`, and README layout inside this folder mirrors where the
  files belong **in the real Mob repo** — copy them across verbatim when that
  repo is available on the box.

## ⚠️ Before this ships into Mob: verify the assumed APIs

Every Mob-specific call is tagged `# ASSUMED MOB API`. They were written against
a described contract, not verified against the package source (no Mob checkout
was reachable when this was authored). Confirm before merge:

| Assumed API | Used by |
|---|---|
| `mix mob.dev` (file watcher + hot pusher) | `bin/dev-mobile` |
| `mix mob.ping --device <d>` (reachability probe) | `bin/dev-mobile` poll loop |
| `mix mob.connect --device <d>` (foreground IEx) | `bin/dev-mobile` |
| `Mob.Device.subscribe/1` → `{:app_state, :background \| :foreground}` | `Mob.Dev.Connection` |

If `mix mob.ping` does not exist, replace the poll with `Node.ping/1` from a
throwaway node (over the tunnel) or a short-timeout `mix mob.connect` retry.

## Contents

| File | Purpose |
|---|---|
| `bin/dev-mobile` | one-command dev loop (process-group teardown, bounded poll) |
| `lib/mix/tasks/mob.dev.setup.ex` | idempotent setup: per-dev random cookie, `.env.dev`, `.gitignore`, installs the script |
| `lib/mob/dev.ex` | dev-only distribution bootstrap — **no default cookie** (raises if unset) |
| `lib/mob/dev/connection.ex` | supervised lifecycle owner (reconnect-on-foreground) |
| `README-development.md` | the honest Development + Physical Device Networking docs for Mob's README |
