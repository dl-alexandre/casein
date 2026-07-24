# tmux 3.7 cutover runbook

The devbox runs tmux **3.4** (Ubuntu apt package) until this cutover. tmux
**≥ 3.5** queries the attached client for foreground/background colours and
answers in-pane `\e]10;?` / `\e]11;?` queries itself; tmux **≥ 3.6** adds
explicit CSI `?997` dark/light theme reports (mode 2031). DevIDE gates those
features on `TmuxCtl.Client.server_version/0` and is a no-op on 3.4. This
runbook installs **3.7** on the devbox and restarts so the gates open.

**This is disruptive.** `tmux -L devide kill-server` drops the tmux sessions of
**every user on the devbox**, not just yours. Do it only in an announced,
bounded window.

## What ships in the pin

- `scripts/install-tmux.sh` — idempotent source build of tmux **3.7** to a
  prefix (default `/usr/local`, so it precedes the apt tmux in `/usr/bin`).
- CI (`deploy-devbox.yml`, `pty-tests.yml`) builds 3.7 (cached) so the `:pty`
  and `:tmux` suites validate against the target host version.
- This runbook.

The on-devbox install + restart is **run by hand** in the window (below); it is
not automated, so the disruptive step is never triggered by a deploy.

## Why 3.7 (not 3.6b)

3.7 keeps every DevIDE-targeted 3.6 capability (theme `997`, literal tabs in
`capture-pane`, `pane-border-lines single`, extended-keys send-keys) while
picking up upstream paste/escape-timing fixes, name sanitization, and stability
fixes on paths DevIDE already uses (`load-buffer` / `paste-buffer`, forwarded
OSC/CSI queries on the attach PTY). Floating panes and other 3.7 UI features are
not enabled in `priv/tmux/devide.conf`.

## Cutover steps (on the devbox, in the window)

1. **Announce** the window to devbox users; confirm no critical session is live.
2. **Install 3.7** to `/usr/local/bin` (precedes `/usr/bin`):
   ```sh
   sudo TMUX_PREFIX=/usr/local bash /data/workspaces/dalexandre/dev_ide/scripts/install-tmux.sh
   tmux -V   # expect: tmux 3.7   (resolves via PATH to /usr/local/bin)
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
   tmux -L devide display-message -p '#{version}'   # expect: 3.7
   ```
6. **Smoke-check in-pane detection** — open a DevIDE terminal with **two**
   browser viewers on the same session, then in the pane:
   ```sh
   bash -c 'printf "\e]11;?\a" > /dev/tty; IFS= read -rs -t 2 -d $'"'"'\a'"'"' ans < /dev/tty; printf "%q\n" "$ans"'
   ```
   Expect **exactly one** `\e]11;rgb:…` reply matching the session background.
   Flip the browser scheme (dark↔light), wait ~1 s, re-run: the reply must show
   the new background and `tmux -L devide show-environment CASEIN_TERMINAL_SCHEME`
   must agree.
7. **Smoke-check explicit theme reports** (3.6+ only):
   ```sh
   bash -c 'printf "\e[?996n" > /dev/tty; IFS= read -rs -t2 ans < /dev/tty; printf "%q\n" "$ans"'
   ```
   Expect `\e[?997;1n` (dark) or `\e[?997;2n` (light) matching the web theme.

## Rollback (also disruptive — same window discipline)

If 3.7 shows a terminal regression, revert to the apt tmux and restart:

```sh
sudo rm -f /usr/local/bin/tmux            # unpin; PATH falls back to /usr/bin (apt 3.4)
tmux -V                                    # expect: tmux 3.4
tmux -L devide kill-server 2>/dev/null || true
tmux -L devide_dev kill-server 2>/dev/null || true
sudo systemctl restart devide
```

The theme report code re-gates itself off automatically once the server
reports 3.4 again — no code revert needed. Also revert the CI/install pin if
3.7 is abandoned, so the `:pty` suite matches the box again.

## Known caveats (accepted, not blocking)

- `Terminals.tmux_version/0` is a single global value. If per-workspace
  **container** tmux returns, it must become per-session / per-attachment-target
  (host-tmux fallback is fine today).
- The client colour report covers **fg/bg only** (OSC 10/11). Full palette
  (OSC 4), named themes, and app-specific config still go through the
  `Casein.Terminals.ToolThemes` registry path.
- 3.7 changes theme send timing ("do not send theme unless changed"); re-run the
  smoke checks above after cutover.
