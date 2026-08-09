# Mob dev workflow — verified, and the `contrib/mob-tooling` correction

> **Provenance:** verified against a real checkout of the Mob framework —
> `github.com/GenericJam/mob` @ `d4d0717` (pulled to `/data/workspaces/dalexandre/mob`).
> File:line citations are into that checkout. This **retires** the speculative
> `contrib/mob-tooling/` tree, which was written against assumed Mob APIs that
> mostly do not exist.

## Why the staged tooling was removed

`contrib/mob-tooling/` proposed a one-command `bin/dev-mobile` loop wrapping
`mix mob.dev` / `mob.ping` / `mob.connect`, plus a `Mob.Dev` distribution module,
a `Mob.Dev.Connection` lifecycle GenServer, and a `mix mob.dev.setup` task. Every
Mob-specific call carried a `# ASSUMED MOB API` tag because no Mob source was
reachable when it was written. With the real source in hand, those assumptions
resolve as:

| Assumed API | Verdict | Reality |
|---|---|---|
| `mix mob.dev` | **ABSENT** | No such task. The dev loop is `mix mob.connect` then manual hot-push `nl(MyApp.SomeScreen)` (README.md:242-243). File-watching, if any, lives in the separate `mob_dev` package, not here. |
| `mix mob.ping --device <d>` | **ABSENT** | No reachability task. `Mob.Dist` itself waits on EPMD and skips gracefully after 10s (dist.ex:21, :216-220). |
| `mix mob.connect --device <d>` | **DIFFERENT** | Real, but in the separate `mob_new`/`mob_dev` archive (`mix archive.install hex mob_new`, README.md:39,42,265) — and it takes **no `--device` flag**; it tunnels + opens IEx to running nodes (README.md:226,242). |
| `Mob.Device.subscribe/1` → `{:app_state, :background \| :foreground}` | **DIFFERENT** | `subscribe(category \| [category] \| :all)` (device.ex:90-93). Messages are `{:mob_device, event}` / `{:mob_device, event, payload}` — app lifecycle arrives as **bare atoms**: `{:mob_device, :did_enter_background}`, `{:mob_device, :will_enter_foreground}` (device.ex:51-57, README.md:204-205). No `:app_state` wrapper. |
| `Mob.Dev.ensure_distribution!` (my module) | **REDUNDANT** | `Mob.Dist.ensure_started(node:, cookie:)` already exists, is platform-aware (iOS sets node+cookie at BEAM launch; Android defers to avoid an hwui-race SIGABRT), waits for the tunneled EPMD, and calls `Node.start(node, :longnames)` + `Node.set_cookie/1` (dist.ex:60-61, :179-221). |

Keeping fictional code that calls non-existent `mix mob.*` tasks and duplicates
`Mob.Dist` is worse than removing it, so the `contrib/mob-tooling/` tree is
deleted. Git history preserves it.

## The real Mob development workflow

OTP runs **embedded on the device** (no server). Development is over Erlang
distribution after a tunnel is established (README.md:226-249):

```bash
# From the mob_new/mob_dev archive (not the `mob` core package):
mix mob.connect                              # sets up adb reverse / iproxy tunnel + opens IEx

# In IEx, hot-push changed modules (no restart):
nl(MyApp.SomeScreen)                         # Mob.Screen handles :__mob_hot_reload__ (screen.ex:237-242)

# Inspect / drive the running app:
Mob.Test.screen(:"my_app_ios@127.0.0.1")     #=> MyApp.CounterScreen
Mob.Test.assigns(:"my_app_ios@127.0.0.1")    #=> %{count: 3, ...}
Mob.Test.tap(:"my_app_ios@127.0.0.1", :increment)
```

Distribution is brought up by the app calling `Mob.Dist.ensure_started/1` from
its `on_start/0` (Android), or implicitly at BEAM launch (iOS):

```elixir
Mob.Dist.ensure_started(node: :"my_app@127.0.0.1", cookie: session_cookie)
```

Lifecycle handling is a plain `handle_info` in your screen (README.md:204-205):

```elixir
def handle_info({:mob_device, :did_enter_background}, socket), do: ...
def handle_info({:mob_device, :will_enter_foreground}, socket), do: ...
```

## What survives from the original critique

- **Tunnel-not-Wi-Fi security model:** validated. `Mob.Dist` is built around a
  tunneled EPMD (`adb reverse tcp:4369`), not Wi-Fi exposure (dist.ex:18-21).
- **Per-developer cookie instead of a shared default:** partly real already —
  Mob supports per-session cookies and rotation without restart
  (`Node.set_cookie(new_session_cookie)`, dist.ex:161-167). But its quickstart
  examples still use a static `cookie: :secret` (README.md:84). A generator that
  emits a random per-developer cookie would be a small, genuine enhancement — but
  it belongs in **`mob_new`'s** project generator, not in casein.

## Mob has no terminal — the ghostty sketch premise was unfounded

`contrib/mob-tooling/TERMINAL-INTEGRATION-SKETCH.md` imagined embedding a
`ghostty_ex` terminal as a native Mob view. Mob has **no ghostty/terminal
anything** — UI renders via Compose (Android) and SwiftUI (iOS), and `grep
ghostty` over the whole repo is empty (mix.exs deps 198-226). casein is the real
`ghostty` user; its verified terminal contract lives in
[`ghostty_terminal_contract.md`](ghostty_terminal_contract.md). The "native
ghostty terminal in a Mob app" idea has no basis in either codebase and is
dropped.

## Companion theme kit (`CaseinMob.Theme`) — settled

Inventory decision for #740: the companion **does** have a theme kit, and it is
**not** Hex `mob_themes`.

| Candidate | Verdict |
|---|---|
| Hex `mob_themes` (Obsidian / Citrus / Birch / …) | **Dead weight for Casein.** Stock Mob showcase pack. Was declared as `:default_style` and made devices boot Obsidian violet after `Mob.Plugins.boot/1` clobbered the brand theme. Removed from `native/casein_mob` deps and `mob.exs`. |
| Untracked `native/devide_mob/deps/mob_themes` | Working-tree leftover from the rename; not source of truth (do not copy). |
| In-tree brand theme (git history: `DevideMob.Theme` @ `a0b3563e`) | **Live.** Restored as `CaseinMob.Theme` — web cockpit palette (OKLCH→sRGB), applied via `use Mob.App, theme: CaseinMob.Theme` and re-asserted in `CaseinMob.App.on_start/0`. Home screen light/dark switcher uses `CaseinMob.Theme.light/0` and `.dark/0`. |

Product screens already speak semantic tokens (`:primary`, `:surface`, …); those
resolve against the active `Mob.Theme`. Severity/status colours are out of scope
here — consume web cockpit tokens from #729 / PR #771 when they land, do not
fork a parallel palette in the companion.

`config :mob, :styles` stays `[]` and `:default_style` stays unset so a stock
style package cannot silently win at boot again.
