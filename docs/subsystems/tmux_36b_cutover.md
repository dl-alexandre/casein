# tmux 3.6b cutover runbook

The devbox runs tmux **3.4** (Ubuntu apt package). tmux **≥ 3.5** queries the
attached client for foreground/background colours and then answers in-pane
`\e]10;?` / `\e]11;?` queries itself, which is what lets *unregistered* TUIs in
DevIDE panes auto-detect light/dark. The code that reports the session theme to
the client is already merged (version-gated, a no-op on 3.4). This runbook
installs 3.6b on the devbox and restarts so that gate opens.

**This is disruptive.** `tmux -L devide kill-server` drops the tmux sessions of
**every user on the devbox**, not just yours. Do it only in an announced,
bounded window.

- **Scheduled window:** Sunday 2026-07-05, 04:00–04:30 UTC.
- **Prerequisite:** the B2 code half (PR #110) must be merged first — on 3.6b
  every client attach triggers a colour query, and #110 is what answers with a
  single, session-consistent reply.

## What ships in this PR

- `scripts/install-tmux.sh` — idempotent source build of a pinned tmux to a
  prefix (default `/usr/local`, so it precedes the apt tmux in `/usr/bin`).
- CI (`deploy-devbox.yml`, `pty-tests.yml`) builds 3.6b (cached) so the `:pty`
  suite validates against the target version.
- This runbook.

The on-devbox install + restart is **run by hand** in the window (below); it is
not automated, so the disruptive step is never triggered by a deploy.

## Cutover steps (on the devbox, in the window)

1. **Announce** the window to devbox users; confirm no critical session is live.
2. **Install 3.6b** to `/usr/local/bin` (precedes `/usr/bin`):
   ```sh
   sudo TMUX_PREFIX=/usr/local bash /data/workspaces/dalexandre/dev_ide/scripts/install-tmux.sh
   tmux -V   # expect: tmux 3.6b   (resolves via PATH to /usr/local/bin)
   ```
3. **Cut over the DevIDE tmux servers** (mixed client/server on one socket is
   unsupported, so the servers must be killed and recreated):
   ```sh
   tmux -L devide kill-server 2>/dev/null || true
   tmux -L devide_dev kill-server 2>/dev/null || true
   ```
4. **Restart DevIDE** so it re-execs against the new binary and clears the
   cached server version (`persistent_term`):
   ```sh
   sudo systemctl restart devide      # or the deploy poller's restart path
   ```
5. **Verify the server version** DevIDE will see:
   ```sh
   tmux -L devide display-message -p '#{version}'   # expect: 3.6
   ```
6. **Smoke-check in-pane detection** — open a DevIDE terminal with **two**
   browser viewers on the same session, then in the pane:
   ```sh
   bash -c 'printf "\e]11;?\a" > /dev/tty; IFS= read -rs -t 2 -d $'"'"'\a'"'"' ans < /dev/tty; printf "%q\n" "$ans"'
   ```
   Expect **exactly one** `\e]11;rgb:…` reply matching the session background
   (Catppuccin Mocha base ≈ `1e1e/1e1e/2e2e`). Flip the browser scheme
   (dark↔light), wait ~1 s, re-run: the reply must show the new background and
   `tmux -L devide show-environment DEV_IDE_TERMINAL_SCHEME` must agree.

## Rollback (also disruptive — same window discipline)

If 3.6b shows a terminal regression, revert to the apt tmux and restart:

```sh
sudo rm -f /usr/local/bin/tmux            # unpin; PATH falls back to /usr/bin (apt 3.4)
tmux -V                                    # expect: tmux 3.4
tmux -L devide kill-server 2>/dev/null || true
tmux -L devide_dev kill-server 2>/dev/null || true
sudo systemctl restart devide
```

The B2 report code re-gates itself off automatically once the server reports
3.4 again — no code revert needed. Also revert the CI workflow pin (this PR) if
3.6b is abandoned, so the `:pty` suite matches the box again.

## Known caveats (accepted, not blocking)

- `Terminals.tmux_version/0` is a single global value. If per-workspace
  **container** tmux returns, it must become per-session / per-attachment-target
  (host-tmux fallback is fine today).
- The client colour report covers **fg/bg only** (OSC 10/11). Full palette
  (OSC 4), named themes, and app-specific config still go through the
  `DevIDE.Terminals.ToolThemes` registry path.
