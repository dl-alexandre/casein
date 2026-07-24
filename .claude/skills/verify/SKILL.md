---
name: verify
description: Verify DevIDE changes end-to-end by running a dev server from the current checkout and driving the real viewer headlessly. Use before committing nontrivial runtime changes (terminal rendering/sizing, LiveView surfaces, viewer UI).
---

# Verify DevIDE changes end-to-end

Never verify against the deployed release at `:4000` for local changes — it runs
`origin/master`, not your diff. Run a dev server from the checkout instead.

## Boot a dev server from this checkout

```bash
mise exec -- mix deps.get            # once per fresh worktree
cd assets && npm install && cd ..    # once, for esbuild bundling
PORT=4213 ELIXIR_ERL_OPTIONS="+JMsingle true" mise exec -- mix phx.server
```

Gotchas:
- On the devbox the dev endpoint binds a **Unix socket**
  (`/run/casein/instances/<id>.sock`, printed in the boot log), not TCP.
  Bridge it: `socat TCP-LISTEN:4213,bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:<sock>`.
- The dev server uses its own tmux server (`tmux -L devide_dev`) — scratch
  sessions there can never disturb the user's prod tmux (`devide` label).
- Auth on loopback: send header `X-Auth-Request-Email: dalexandre@milcgroup.com`.

## Drive the viewer headlessly

playwright-core lives at `/home/devbox/.npm/_npx/*/node_modules/playwright-core`,
chromium at `~/.cache/ms-playwright/chromium-*/chrome-linux64/chrome`.

1. Scratch terminal session named to DevIDE's pattern
   (`devide_<workspace-name>_<sid>`, see `TmuxPolicy.session_name/2`):
   `tmux -L devide_dev new-session -d -s devide_devbox-smoke_u-<slug> -x 80 -y 24`
2. Navigation is **path-based**: the viewer URL is the workspace filesystem
   path, e.g. `http://127.0.0.1:4213/devbox-smoke?session=<sid>&tmux_session=<full-name>`.
   (`/workspaces/<uuid>` 302s away for stale ids; workspaces sync from
   `/data/workspaces` on dashboard load — `devbox-smoke` is a safe target.)
   Never pass `?window=`/`?pane=` against a user's real session — those select
   globally and yank the user's attached view.
3. Observe from both sides: `page.evaluate` on the
   `[phx-hook='GhosttyTerminal']` element (dataset cols/rows, rect) **and**
   `tmux -L devide_dev list-windows -t <session> -F '#{window_id} #{window_width}x#{window_height}'`.
   Terminal-size assertions: the tmux window must follow the viewport
   (`viewport / ~8.4px cols, / 17px rows`, minus chrome), not sit at 80x24.

## Clean up

Kill the scratch tmux session, the socat bridge, and the dev server when done.

## Reading the size policy at runtime

`SessionOwner` logs `terminal owner size -> WxH (reason)` and
`tmux window drift WxH -> re-asserting WxH` at info level — on the deployed
release read them with `journalctl -u devide-<instance>.service`. A repeated
`focused` size immediately overridden by another `focused` size is a viewer
double-report; drift lines every 30s mean the owner is fighting something.
