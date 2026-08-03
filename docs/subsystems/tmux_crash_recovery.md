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
   `casein-tmux.service` so the `-L casein` server is forked at boot, with
   `Restart=on-failure` (verified: SIGSEGV → auto-restart) and
   `LimitCORE=infinity`.
   **Caveat: systemd cannot adopt a server that is already running.**
   `Type=forking` takes MainPID from the process left in the unit cgroup, so a
   server started outside systemd is never tracked — it keeps `Max core file
   size 0` and gets no auto-restart. The installer therefore *enables* the unit
   but only *starts* it when the server is down. Supervision of an existing
   orphan server begins only after a deliberate handover:
   `tmux -L casein kill-server && sudo systemctl start casein-tmux`.
9. **Version pin** — the pin lives in **`scripts/install-tmux.sh`** and is the
   single source of truth (currently **tmux 3.7**, which is what the devbox
   runs). Reinstall with `bash scripts/ensure-casein-tmux.sh
   --reinstall-binary`. Do not restate a version in `ensure-casein-tmux.sh` or
   here: the two drifted (3.6b vs 3.7) and `--reinstall-binary` silently
   downgraded the running server.

## Ops

```bash
# Pin binary + start keepalive
bash scripts/ensure-casein-tmux.sh --reinstall-binary

# Core dump notes for /usr/local/bin/tmux
bash scripts/ensure-tmux-coredumps.sh

# Watch recoveries
# (audit action: terminal.session_recreated)
```

## Known gaps (post-mortem is currently near-impossible)

The 2026-08-03 02:25 server death could not be root-caused. Before trusting a
future investigation, check these:

- **No core dump.** `core_pattern` pipes to apport, which ignores unpackaged
  binaries — and `/usr/local/bin/tmux` is unpackaged (`dpkg -S` finds nothing).
  A segfault leaves no artifact unless the server runs under
  `casein-tmux.service` (`LimitCORE=infinity`) *and* apport is bypassed.
- **Short journal window.** `SystemMaxUse` was 1G, which on this box is ~7
  hours: `devbox-manager`'s oauth2-proxy emits ~2.8M entries per 7h (one per
  token validation, ~98.7% of all journal volume) and `deploy-poller.sh`
  streams full `mix test` + coverage output. Raised to 8G via
  `/etc/systemd/journald.conf.d/99-casein-forensics.conf` (~2.5 days). The
  durable fix is `--standard-logging=false` on oauth2-proxy in
  `/opt/devbox/manager/lib/oauth2proxy.js` (separate product).
- **Kernel log unreadable.** `kernel.dmesg_restrict=1`, so OOM kills cannot be
  confirmed or excluded from an unprivileged agent shell.
- **The archive has no reaper.** `ScrollbackArchive` only deletes on explicit
  `delete/1` (intentional session kill); nothing prunes by age or count. It
  reached 10,679 files / 488 MB in under 30 days. `config/test.exs` now
  sandboxes the suite's spill (that was 98.8% of it — see
  `ScrollbackArchiveSandboxTest`), but real sessions still accumulate forever.

## Intentionally not restored

- Full multi-pane process trees that were only in live panes (rebuild via
  template + agents restarting themselves).
- More history than the archive cap (raise
  `:tmux_scrollback_archive_bytes` if needed).
