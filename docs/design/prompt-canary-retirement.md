# Prompt canary retirement after deploy handoff — design pass

Status: **analysis + recommendation, implementation deferred pending sign-off**
Date: 2026-07-08
Prompted by: the 2026-07-07 "narrow column" incident (PRs #148/#150/#151)

## Problem

After a deploy activates a new canary, the **old** instance can keep running
for up to **30 minutes**. During that window it holds a tmux client per live
session, its Unix socket, and its `SessionOwner` processes — and until PR #150
those owners fought the new instance over the shared tmux window size on every
30-second drift tick, snapping the operator's terminal between two sizes twice
a minute.

PR #150 stopped the *fighting* (draining owners no longer write to tmux). But
the old instance still **lingers**, and twice during that incident I had to
retire it by hand (`kill -TERM <MainPID>`) to converge the operator's session.
Manual production surgery on every deploy that leaves a tab open is the smell
this note addresses.

## Why old instances linger

The drain path (`Casein.Deployment.Drain`, see
`docs/subsystems/policy_deploy_export.md` §"Deploy handoff & drain"):

1. `POST /api/drain` marks the instance draining, broadcasts
   `{:update_available, version, commits_behind}` on `"deploy:updates"`, and
   arms a **30-minute hard timeout** (`@hard_ms`).
2. Each live LiveView is monitored via `Drain.track/1`. Only once the
   connection `count` hits **zero** does a 5s grace timer (`@grace_ms`) call
   `System.stop(0)`.

The gap: **connections don't migrate on their own.** The `{:update_available}`
broadcast surfaces a banner, but a backgrounded tab, an idle tab, or a client
that ignores the banner keeps its socket open against the old instance. `count`
never reaches zero, so the instance rides the hard timeout all the way to 30
minutes.

## The insight that de-risks retirement

**tmux sessions and their PTYs survive a BEAM restart.** That is the entire
point of the shared-session architecture (`Terminals.Session` /
`SessionOwner` attach to a tmux server that outlives the node). Retiring an old
instance therefore loses **no terminal state** — a client that reconnects to
the new instance re-attaches to the same tmux session and repaints from the
owner's replay buffer. The manual `kill -TERM` I did twice was safe for exactly
this reason: the sessions were never in the BEAM to begin with.

This means retirement can be *forced* on a bounded schedule rather than waited
out — the conservative "wait for every connection to leave" posture is
protecting state that isn't actually at risk.

## Options

**A. Shorten the hard timeout (30m → ~5m).**
Trivial one-line change. Halves-and-then-some the worst case, but still lingers
minutes, still fights (pre-#150 semantics) or idles (post-#150) for that window,
and risks cutting off a genuinely-active user mid-session at the deadline. A
band-aid, not a fix.

**B. Drain-triggered client reconnect (the graceful fix).**
On `start_drain`, push a client directive that **reconnects the LiveSocket to
`current.sock`** (not a full page reload — a socket reconnect preserves scroll,
panel state, and terminal DOM; buffered output during the blip replays from the
owner). Clients migrate in seconds, `count` drops to zero, and the existing
grace-timer path retires the instance cleanly with no force-kill. This is the
correct primary fix: it makes the *designed* path (stop at count==0) actually
reachable.
Risk: a reconnect blips every live LiveView. Mitigate by reconnecting only when
the tab is visible/idle and deferring a busy terminal's reconnect briefly; a
backgrounded tab reconnects on its next `visibilitychange` (the terminal hook
already listens for this — see `__onLifecycleRefit`).

**C. Deploy-script backstop force-retirement.**
After the new instance passes health, wait a bounded grace (proposal:
`@post_health_drain_grace ≈ 120s`) for connections to migrate, then
`kill -TERM` any old instance still above zero connections. The deploy script
already enumerates old instances and has their pid/socket from the instance
JSON (§"Signal all old instances to drain"); this just adds a timed force-stop
after the drain signal. Safe because of the tmux-survives-BEAM insight. sudo
policy forbids `systemctl stop`, but the canary units are `Restart=no` and
owned by `devbox`, so a direct `kill -TERM <MainPID>` works (it is exactly the
manual step, automated). Log every force-retirement.

**D. B + C together (recommended).**
B makes retirement *graceful and fast* in the common case; C is the *backstop*
that guarantees an old instance can never ride the full 30 minutes even if a
client ignores the reconnect. Keep the 30-minute hard timeout as a final safety
net that should now essentially never fire.

## Recommendation

Ship **D**, in two independently-landable steps:

1. **C first (backstop).** Lowest risk, highest immediate value — it directly
   eliminates the manual `kill` and bounds the linger window to ~2 minutes. It
   touches only the deploy script and is guarded by the tmux-survives-BEAM
   property. Land and observe across a few deploys.
2. **B second (graceful migration).** Removes the force-kill from the common
   path so retirement is clean, not abrupt. Needs client-side care (reconnect,
   not reload; visibility-gated) and its own verification against a live
   two-instance handoff.

## Risks & open questions

- **Non-terminal state in the old BEAM.** Terminal/preview/artifact processes
  are tmux-pane- or worktree-backed and reconstruct on reconnect, but audit
  the supervision tree for any process holding *unflushed, non-reconstructable*
  state before force-kill (C). Drain already `System.stop(0)`s at count==0, so
  anything that can't survive that is already broken; C only changes *when*.
- **In-flight HTTP/MCP requests** on the old socket at force-kill get dropped.
  The `current.sock` symlink already points at the new instance, so new
  requests land there; only requests mid-flight on the old socket are affected.
  Bound is small (seconds). Acceptable, but note it.
- **Reconnect storm (B).** A synchronized reconnect of every client at drain
  could thundering-herd the new instance. Jitter the client reconnect (the
  terminal client already has `reloadWithJitter` precedent).
- **This change is now guarded.** The `terminal.size_fight` alert (this branch)
  fires a drawer notification if two instances ever fight again — so a
  regression in retirement announces itself instead of needing a screenshot.

## Verification plan

The `.claude/skills/verify/SKILL.md` recipe (dev server + scratch tmux on the
`casein_dev` label + headless viewer) plus a scripted two-instance handoff:
start instance A, attach a headless viewer, activate instance B, and assert
(1) the viewer's tmux window size never oscillates and (2) instance A's process
is gone within the bounded grace. This is the same observation loop that caught
the original incident.
