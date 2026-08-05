# Mobile Terminal security architecture decision

Status: accepted for phased implementation

## Decision

Casein Mobile Terminal is an explicit elevated raw-shell surface backed by a
fresh, server-owned disposable tmux session. It uses Casein's authenticated
Phoenix WebSocket and `Casein.Terminals.SessionOwner`. Ghostty parses and renders
VT bytes on-device. Remux may inform or supply selectively reviewed MIT-licensed
iOS rendering/input patterns, but Casein does not adopt Remux's direct SSH,
Citadel, saved server credentials, arbitrary tmux attachment, SFTP, shortcuts,
or product shell.

The first product phase is read-only. Write mode requires a separate explicit
elevation and a one-writer lease after read-only lifecycle and privacy gates
pass on signed physical iPad and Android builds.

## Why direct SSH is rejected

Direct SSH would place server credentials and host-trust state on the mobile
device and would let a client execute tmux control commands outside Casein's
workspace, origin, lifecycle, pane-role, policy, and audit boundaries. Casein
already owns the correct transport seam: `SessionOwner` supplies bounded replay,
ordered live bytes, input, resize, reconnect, and tmux-backed persistence.

The mobile app is therefore a constrained subscriber to Casein, never a general
SSH or tmux client.

## Credential and topic boundary

Pairing and durable device-link credentials grant the mobile projection and
declared-action capabilities advertised by `Casein.DeviceLinks`. They do not
grant raw terminal access. Those socket credentials are denied the ordinary
`terminal:*` topic before workspace or session resolution.

The future `mobile_terminal:*` topic requires a separate short-lived child
grant. Until that grant and channel are implemented, every credential is denied
mobile-terminal admission. The durable device token is not expanded with a raw
terminal capability.

## Feature policy and kill switch

Mobile Terminal is doubly off by default:

- deployment `enabled` is false;
- the kill switch is active.

Releasing both switches is still insufficient. The authenticated user ID,
durable device-link ID, and workspace ID must all exactly match separate
allowlists. The kill switch always wins. This feature policy is only an initial
gate and never substitutes for child-grant or lifecycle authorization.

Runtime controls:

- `CASEIN_MOBILE_TERMINAL_ENABLED`
- `CASEIN_MOBILE_TERMINAL_KILL_SWITCH` (only an explicit false releases it)
- `CASEIN_MOBILE_TERMINAL_USER_IDS`
- `CASEIN_MOBILE_TERMINAL_DEVICE_LINK_IDS`
- `CASEIN_MOBILE_TERMINAL_WORKSPACE_IDS`

Allowlist values are comma-separated exact identifiers. Wildcards are not
supported.

## Child-grant contract

The child grant is short-lived, independently revocable, and bound to:

- JTI and digest-at-rest token identity;
- subject and durable device-link ID;
- canonical origin ID and immutable origin incarnation;
- exact workspace and host;
- durable mobile-terminal lease and lifecycle generation;
- server-generated logical SID and recorded tmux session;
- exact pane ID and required `mobile_terminal` role;
- topology generation;
- read or write mode;
- issue, begin-use, active, idle, and absolute expiry;
- connection generation and, for write mode, writer identity.

The raw token is returned only in a successful create/refresh response, is
redacted from all observability, and remains memory-only on-device. Join allows
one bounded begin-use. Reconnect refreshes through the still-valid durable device
link and never restores an expired child grant from disk. Rotation, revocation,
or expiry of the parent device link cascades immediately to every child grant.

Every join and input batch authorizes against durable server state. Signed
claims alone are never authoritative. Inactive origin, policy/flag changes,
kill switch, deletion, expiry, pane replacement, role drift, or topology
generation mismatch stop output and input immediately and fail closed.

## Lifecycle contract

The server generates the session name, SID, pane, role, cwd, shell policy, and
TTL. It creates one dedicated disposable session and never discovers or reuses a
focused, recent, operator, agent, verify, or unrelated session. Ordinary browser
terminal and MCP mutation surfaces reject reserved mobile-owned sessions.

Creation is idempotent by device link and client request ID; a changed payload
under the same key rejects. Deletion requires the opaque lease ID plus a new
request ID. Foreign and unknown lease IDs receive the same non-enumerating
response.

Cleanup blocks attach/input, stops the exact owner, stops the exact PTY, kills
only the recorded tmux session, verifies absence, then marks the lease deleted.
Retries and startup reconciliation preserve that exact identity. Raw terminal
bytes never enter durable scrollback archives.

## Read and write authority

Read mode receives bounded replay and ordered live output. It may submit a
bounded active-viewer resize. Input, paste, controls, files, previews, uploads,
and topology mutation reject.

Write mode is arbitrary shell authority inside the dedicated workspace shell;
it is not a declared safe action. Every input carries the active grant,
connection generation, and monotonic client sequence. Duplicate or lower
sequences do not execute again, gaps require resynchronization, reconnect
invalidates the old writer, and input is never queued offline. Writer takeover
revokes and confirms cutoff of the old writer before activating the new one.

## Audit and privacy allowlist

Terminal contents may include source, logs, secrets, credentials, customer data,
shell history, clipboard payloads, and hostile escape sequences. Raw bytes,
commands, rendered cells, clipboard values, and environment content are never
placed in Live Work, Needs Me, notifications, audit, logs, telemetry,
accessibility labels, app-switcher/background snapshots, automated test
artifacts, crash data, or durable mobile cache.

Audit permits only typed metadata:

- event and result/reason code;
- actor and device-link opaque IDs;
- canonical origin, workspace, lease, session, and pane opaque IDs;
- lifecycle/connection generation and mode;
- byte count and sequence (never bytes);
- timestamps.

The terminal is foreground-only, masks on background, disables input whenever
offline/cached, and purges bounded in-memory VT state on delete, revoke, expiry,
or origin/profile switch. System capture/recording is detected or masked where
the platform supports it. User-triggered screenshots cannot be universally
prevented on iOS and are disclosed as an elevated-mode risk.

OSC52, links, previews, file transfer, saved commands, port forwarding,
multi-pane topology, and existing-session attachment remain disabled until each
receives a separate threat model and rollout decision.

## Separation from Needs Me and Live Work

Needs Me remains the decision-only surface for bounded server-declared actions
with revision and exact-session revalidation. Live Work remains a privacy-safe
projection. Neither surface receives, parses, summarizes, caches, or infers
state from raw terminal output.

A card may navigate to Terminal, but it cannot embed a child grant or deliver
terminal input. Entering Terminal always performs a fresh elevation and visibly
names the canonical origin, workspace, and dedicated session.

## Rollout gates

1. Land this ADR, fail-closed feature policy, kill switch, and credential/topic
   denial tests with no mobile terminal route exposed.
2. Prove exact disposable lifecycle and no-archive behavior using fake and real
   adapters without touching existing sessions.
3. Add the authenticated read-only child grant/channel; prove isolation,
   revocation, bounded replay, resource limits, and privacy on signed iPad and
   Android builds.
4. Add explicit write elevation only after one-writer, sequencing, stale,
   offline, replay, and wrong-pane adversarial proofs pass physically.
5. Begin limited allowlisted dogfood behind the kill switch. Expansion requires
   a new threat model and the normal narrow-PR, exact-head gate, deploy, and
   physical revalidation process.
