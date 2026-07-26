# tmux crash / session-wipe recovery

Casein treats the host tmux server (`-L casein`) as the durable boundary for
live sessions. When that server dies (segfault, OOM, `kill-server`, host
reboot), every pane, layout, and in-tmux scrollback is gone. This doc
describes the mitigations that keep the cockpit usable.

## What survives what

| Event | History | Layout | Auto shell back? |
|-------|---------|--------|------------------|
| Tab close / LiveView crash | Yes (tmux) | Yes | Yes |
| BEAM restart, tmux up | Yes (capture-pane seed) | Yes | Yes |
| **tmux server death** | Archive tail only | Auto re-apply last template | Yes (SessionOwner recover + LiveView retry) |

## Mitigations (code)

1. **LiveView auto-reattach** — `recoverable_pane_exit?/1` accepts erlexec
   exit statuses and other term_exit shapes, bounded by
   `@pane_auto_retry_limit`.
2. **SessionOwner backend recover** — shell owners with live subscribers
   re-open the Session attachment on `term_exit` instead of stopping; up to
   5 attempts with backoff.
3. **Scrollback archive** — `Casein.Terminals.ScrollbackArchive` spills a
   bounded tail (default 256 KiB) to ETS + disk under
   `~/.casein/tmux-scrollback` (override via `CASEIN_TMUX_SCROLLBACK_DIR`);
   fresh creates reseed when archive has data. Intentional `Tmux.kill/1`
   deletes the archive so the next open is not a false recovery.
4. **Recovery banner + audit** — SessionOwner notifies (manager UUID) after
   recover when the session was missing; `SessionRecovery` emits
   `terminal.session_recreated` audit + PubSub
   `{:terminal_recovery, notice}` for the workspace LiveView flash (deduped 5s).
5. **Template re-apply** — last applied template id is stored in
   `TemplatePreference`; on recovery the LiveView auto-applies it (default
   fallback `agent_pair`).
6. **Softer create geometry** — `new-session -A` no longer passes `-x/-y`;
   size is applied via winsz + `resize-window` after create. Resize-window
   is rate-limited (150 ms) in SessionOwner.
7. **`exit-empty off`** — `priv/tmux/casein.conf` keeps the server process
   alive after the last session is destroyed.
8. **Keepalive unit** — `scripts/ensure-casein-tmux.sh` installs
   `casein-tmux.service` so the `-L casein` server is forked at boot.
9. **Version pin** — cutover target remains **tmux 3.6b**
   (`scripts/install-tmux.sh`); reinstall with
   `bash scripts/ensure-casein-tmux.sh --reinstall-binary`.

## Ops

```bash
# Pin binary + start keepalive
bash scripts/ensure-casein-tmux.sh --reinstall-binary

# Core dump notes for /usr/local/bin/tmux
bash scripts/ensure-tmux-coredumps.sh

# Watch recoveries
# (audit action: terminal.session_recreated)
```

## Intentionally not restored

- Full multi-pane process trees that were only in live panes (rebuild via
  template + agents restarting themselves).
- More history than the archive cap (raise
  `:tmux_scrollback_archive_bytes` if needed).
