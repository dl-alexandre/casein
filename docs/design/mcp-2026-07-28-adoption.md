# MCP 2026-07-28 adoption

> Status: **implemented** on `agent/claude/adhoc-20260730022907`, Slices 0-5.
> Direction for migrating Casein's three MCP servers — preview, terminal,
> artifact — onto MCP spec `2026-07-28`, and for adopting the Tasks and Apps
> extensions.
>
> **What landed, and the one deliberate gap.** Slices 0-4 are complete as
> described below. Slice 5 ships *discovery* only: RFC 9728 protected-resource
> metadata plus the `WWW-Authenticate` challenge that points at it, both gated on
> `:mcp_authorization_servers` and therefore inert until configured. Token
> verification still goes through the existing bearer path in
> `plugs/api_auth.ex` — swapping that for IdP-issued token validation is a
> separate change, because that plug fronts the entire read-only API and Casein
> has no authorization server of its own (the IdP behind oauth2-proxy would be
> it). Discovery is the half that is safe to land now and is the prerequisite
> for the other half.
>
> Also still open: `notifications/tasks` is delivered, but no tool yet produces
> `input_required`, so the MRTR/`tasks/update` path is implemented and tested
> without a real producer. The Grok permission gate is the obvious first one.
>
> Sources: [spec changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog),
> [extensions overview](https://modelcontextprotocol.io/docs/extensions/overview),
> [Tasks](https://modelcontextprotocol.io/extensions/tasks/overview),
> [MCP Apps](https://modelcontextprotocol.io/extensions/apps/overview),
> [Claude platform announcement](https://claude.com/blog/bringing-mcp-2026-07-28-to-claude).

## Why this is bigger than a version bump

`MCPEnvelope` advertises `2025-06-18 / 2025-03-26 / 2024-11-05`
(`lib/casein_web/api/mcp_envelope.ex:37`). Adding a fourth string to that list
does **not** get us a 2026-07-28 server, because the new revision removes the
methods our envelope is built around:

| Removed / changed in 2026-07-28 | Where we depend on it |
| --- | --- |
| `initialize` + `notifications/initialized` **removed**; every request carries `_meta["io.modelcontextprotocol/protocolVersion"]`, `clientCapabilities`, `clientInfo` | `mcp_envelope.ex:69-77` — our only handshake, and the sole delivery point for `handler.instructions/1` |
| `ping` **removed** | `mcp_envelope.ex:79` |
| `server/discover` **added, MUST implement** — advertises `supportedVersions`, `capabilities`, `extensions`, `_meta.serverInfo`, `ttlMs`, `cacheScope` | does not exist |
| `Mcp-Session-Id` **removed** from Streamable HTTP; list endpoints MUST NOT vary per connection; cross-call state becomes server-minted handles passed as ordinary tool arguments | `mcp_transport.ex:26`, all of `Casein.Agents.MCPSessions`, the `:mcp_stream` pipeline and GET/DELETE routes at `router.ex:310-319` |
| HTTP GET SSE channel + `resources/subscribe` **replaced** by `subscriptions/listen` (long-lived POST-response stream, opt-in notification types, `io.modelcontextprotocol/subscriptionId`) | `mcp_transport.ex` SSE path; `streaming_hint/0` at `mcp_envelope.ex:120-130` describes the removed mechanism verbatim |
| All results carry required `resultType` (`"complete"` \| `"input_required"` \| `"task"`) | `result/2` at `mcp_envelope.ex:134` |
| `ttlMs` + `cacheScope` **required** on `tools/list` (and `prompts/list`, `resources/*`) via `CacheableResult` | `mcp_envelope.ex:81-84` |
| `Mcp-Method` + `Mcp-Name` **required** request headers on Streamable HTTP POST; mismatch ⇒ `HeaderMismatchError` `-32020` | not validated |
| Tools SHOULD be returned in deterministic order (client cache / prompt-cache hits) | `list_tools/1` + `MCPCapabilityScope.filter_tools/2` ordering is incidental |
| Multi Round-Trip Requests (MRTR) replace server-initiated requests: `InputRequiredResult` with `inputRequests`, client retries with `inputResponses` | n/a today (we never initiate) — but this is how human-in-the-loop gates work now |
| Roots, Sampling, Logging **deprecated**; `logging/setLevel` removed (per-request `_meta["io.modelcontextprotocol/logLevel"]`) | not used — no action |
| OAuth DCR deprecated in favor of Client ID Metadata Documents; `iss` validation (RFC 9207); `application_type` on registration | no OAuth at all today (`plugs/api_auth.ex` is bearer-only) |

Two pieces of good news:

- **Our error codes stay legal.** The renumbering moved spec codes into
  `-32020..-32099` and left `-32000..-32019` implementation-defined and
  grandfathered, so the `-32_003` agent-capability denial at
  `mcp_envelope.ex:93` does not collide with the new
  `MissingRequiredClientCapability` (`-32021`).
- **The shared-envelope design pays off.** `initialize`, version negotiation,
  and notification routing already live in exactly one module for all three
  servers, so the dual-stack work below is one file, not three.

### Hazard: `cacheScope` on a capability-filtered tool list

`tools/list` is filtered per-token by `MCPCapabilityScope.filter_tools/2`, and
optionally rewritten by `MCPToolSearch` when `DEV_IDE_MCP_TOOL_SEARCH` is on. The
new `CacheableResult` fields make caching explicit, and `cacheScope: "public"`
permits **shared intermediaries** to cache the response. A capability-scoped tool
list served as `public` would let an intermediary hand one agent's scoped tool
surface to another.

Every `tools/list` result from a scoped token MUST be `cacheScope: "private"`.
Treat this as a review gate on Slice 0, not a detail.

Note the spec's "list endpoints no longer vary per-connection" constraint is
satisfied by our design: our variance is derived from the **bearer token**, not
from a session id, so identical credentials always produce an identical list.
`MCPToolSearch` is the one thing to re-check — if it ever varies output for the
same token, it violates this.

## Slices

Ordering is forced by dependency: Tasks negotiation happens through
`server/discover` and per-request `_meta` capabilities, so the core dual-stack
lands first. Slice 0 is a prerequisite, not a nice-to-have.

### Slice 0 — core dual-stack in `MCPEnvelope`

Serve 2026-07-28 and the three older revisions from one handler. Old clients keep
`initialize`/`ping`/`Mcp-Session-Id`; new clients get the stateless path.

1. Add `"2026-07-28"` to `@supported_protocol_versions`, keep
   `@default_protocol_version "2025-03-26"` (the fallback for clients that name
   nothing must stay an *old* version — a client that omits the field is by
   definition not a 2026 client).
2. Resolve the effective version **per request** from
   `_meta["io.modelcontextprotocol/protocolVersion"]`, falling back to the
   session/handshake-derived version for legacy clients. Version mismatch ⇒
   `UnsupportedProtocolVersionError` `-32022`.
3. Implement `server/discover` — `supportedVersions`, `capabilities`
   (`tools: %{}`, plus `extensions` once Slice 1/3 land), `_meta.serverInfo`,
   `ttlMs`, `cacheScope: "public"` (discover output is not token-scoped).
4. Stamp `resultType: "complete"` and
   `_meta["io.modelcontextprotocol/serverInfo"]` on results — **2026 clients
   only** (see compatibility rules below).
5. Add `ttlMs` + `cacheScope` to `tools/list` — again 2026 clients only — and
   sort tools deterministically (safe for every revision, and it improves
   prompt-cache hits for the agents we already run).
   **`cacheScope: "private"` whenever capability scoping applied.**
6. Keep `initialize` and `ping` clauses for old clients; make `streaming_hint/0`
   version-conditional — it is actively wrong for 2026 clients, since it
   instructs them to use a header and a GET channel the revision removed.
7. Find a new home for `handler.instructions/1` (it rides `initialize` today).
   **Open question** — verify whether `server/discover` carries `instructions`
   in the schema before designing around it.
8. Transport: validate `Mcp-Method` / `Mcp-Name` on POST (`HeaderMismatchError`
   `-32020` on mismatch) **only when the request declares 2026-07-28** — see
   the compatibility rules; enforcing this unconditionally is the one change in
   this slice that would break every existing client on the box. Confirm Caddy
   passes both headers through on the public `/api/*/mcp` door. Bonus: they give
   `Plugs.MCPRateLimit` a per-method key it currently has to infer from the body.

#### Compatibility rules for Slice 0

The revision's additions are only additive if they are **emitted** and
**enforced** per-negotiated-version. Three specific traps:

1. **Never enforce the new required request headers on old clients.**
   `Mcp-Method`/`Mcp-Name` are required in 2026-07-28 and absent from every
   client we run. Gate on the request's declared version, defaulting to "old".
2. **Do not add new result fields to old-client responses.** `resultType`,
   `ttlMs`, `cacheScope`, and `_meta.serverInfo` are almost certainly ignored by
   older clients (extra keys in a JSON-RPC result are legal), but "almost
   certainly" is not a property worth betting three servers on. Since Slice 0
   already resolves the version per request, keeping pre-2026 responses
   byte-identical is nearly free and makes the whole slice provably inert for
   existing agents.
3. **Keep `@default_protocol_version` at an old revision.** A request that names
   no version must not be treated as 2026 — `scripts/lib/agent-doctor.sh:245`
   calls `initialize` with `params: {}` and relies on exactly this fallback.

Purely additive, no gating needed: `server/discover` (a new method; old clients
never call it, and unknown methods already return `-32601`), `tasks/*`, and
`subscriptions/listen`.

Gate: `test/casein_web/api/mcp_contract_test.exs` grows a 2026-07-28 arm; every
existing arm must stay green (that's the back-compat proof — Claude Code, Codex,
and Grok on this box all speak older revisions today).

### Slice 1 — Tasks extension: registry + methods

Extension id `io.modelcontextprotocol/tasks`. Statuses `working`,
`input_required`, `completed`, `failed`, `cancelled` (last three terminal).

1. `Casein.Agents.MCPTasks` — the durable handle registry. Model it directly on
   `Casein.Agents.MCPSessions`: ETS table, process monitors on the worker,
   `Process.send_after` sweep against a TTL. That module's docs
   (`mcp_sessions.ex:17-31`) already describe the exact expiry semantics tasks
   need, and it is about to lose its original job — so this is a port, not a new
   pattern. Scope each task to the minting token so `tasks/get` cannot read
   across workspaces.
2. `tasks/get` (poll), `tasks/update` (`inputResponses`, idempotent on duplicate
   keys), `tasks/cancel` (empty ack, cooperative) in `MCPEnvelope`.
3. `CreateTaskResult` with `resultType: "task"` — `taskId`, `status`, `ttlMs`,
   `pollIntervalMs`, `requestState`. Task MUST be durably created before the
   response is sent.
4. Gate on client capability: **never** return a task unless this request's
   `_meta` clientCapabilities declared the extension. Same-tool, both shapes.
5. Advertise `extensions: {"io.modelcontextprotocol/tasks": {}}` in
   `server/discover`.

**Open question:** the SEP-2663 PR summary lists a `pending` status while the
extension overview lists `working`. Pin the enum against the `ext-tasks`
repo schema before writing the state machine.

### Slice 2 — put the long-running tools on Tasks

The tools that exist *because* blocking doesn't work:

- `terminal_wait_agent_state` — the description at
  `terminal_tools/wait_agent_state.ex:7` is the workaround in plain text:
  *"or until timeout_ms elapses (max 55000) … A timeout is not an error —
  re-issue the call to keep long-polling."* That 55s ceiling is a proxy
  constraint, not a real bound on how long an agent takes. As a task, the wait
  becomes `working` → `completed`, survives client restarts, and drops the
  re-issue loop from every caller.
- `preview_record_stop`, artifact build/snapshot, `gate_report` — same shape,
  bounded by wall-clock work rather than a poll window.
- Keep the synchronous path for non-Tasks clients: `taskSupport` is per-tool and
  the server decides per request, so both shapes coexist behind one tool name.

This slice is where the payoff lands for the `devide-remote` flow (off-box
clients on flaky links driving on-box agents).

### Slice 3 — `subscriptions/listen` (optional, after Slice 1)

Replaces the GET SSE channel we have in `mcp_transport.ex`. Worth doing for
`notifications/tasks`, which lets clients drop polling entirely. Note the
revision also removes SSE resumability (`Last-Event-ID`): a broken stream loses
the in-flight request and the client must re-issue with a new request id — which
is precisely why durable task handles come first.

### Slice 4 — MCP Apps

Extension advertised as `io.modelcontextprotocol/ui`, mime type
`text/html;profile=mcp-app`. A tool declares `_meta.ui.resourceUri` pointing at a
`ui://` resource; the host fetches it and renders the HTML in a sandboxed iframe;
the app talks back over a postMessage JSON-RPC dialect (`ui/` methods, plus
`tools/call` proxied through the host). `_meta.ui` also carries `csp` and
`permissions`.

Prerequisite we don't have: **a `resources/*` surface.** All three servers
advertise `capabilities: %{tools: …}` only — no `resources/list`,
`resources/read`, or `resources/templates/list` (grepped; zero hits). Apps needs
at least `resources/read`, with `ttlMs`/`cacheScope` per `CacheableResult`.

Highest-value candidates, in order:

1. **Artifacts.** Every artifact tool currently returns `preview_open_arguments`
   that a caller must hand to Preview MCP's `preview_open` to make anything
   visible — a two-server handshake that only pays off for someone with a Casein
   viewer already open. As an App, `artifact_create`/`artifact_serve` render
   inline. We already build and serve the HTML; this is mostly a `ui://`
   wrapper.
2. **Attention triage.** The "which agent needs me" rollup as a live inline
   panel instead of a JSON blob.
3. **Terminal capture / pane picker.** `terminal_capture` output and the
   `candidate_sessions` disambiguation prompt are both list-and-pick
   interactions that read badly as text.

### Slice 5 — authorization

`plugs/api_auth.ex` is bearer-only across four token kinds (env global,
workspace-scoped, DB-backed orchestrator, `grokcap_` capability). No
`.well-known` protected-resource metadata anywhere. That is why the public door
needs a pasted bearer plus a Caddy `@bearer` bypass, and why
`ApiAuth.actor/1` can only attribute audit entries as coarse
`"ws:<id>"` / `"global"` strings.

We already run oauth2-proxy in front of the host, so OIDC-aligned MCP auth means
the MCP endpoints ride the identity we have rather than a parallel token system —
with real per-user attribution in `Casein.Agents.MCPAudit` as the payoff. Note
DCR is deprecated in favor of Client ID Metadata Documents, so build toward that,
and the org-wide provisioning story lives in the separate
Enterprise-Managed Authorization extension.

Largest blast radius of any slice (that plug gates the whole read-only API, not
just MCP) — plan it on its own.

## MCP tunnels

The platform announcement also lists MCP tunnels: reaching a private MCP server
with no public endpoint and no firewall changes. That is the sanctioned version
of what the `devide-remote` skill does by hand today (SSH tunnel to loopback:4000
+ bearer, or public HTTPS with a Caddy bearer bypass). Not a spec change and not
a slice — but it likely deletes half that skill, so re-evaluate it after Slice 5
rather than hardening the current doors.

## Impact on other agents on this box

Every on-box runtime (Claude, Codex, Grok — see `Casein.Agents.MCPMaterializer`)
and every off-box `devide-remote` client keeps working unchanged, because
negotiation is client-driven: they ask for a 2025-era revision, we echo it, and
under the compatibility rules above they receive byte-identical responses. Their
materialized MCP configs don't change either — same three endpoint URLs, same
bearer auth. The in-repo wire clients (`scripts/verify_agent_pairing.sh:148-231`,
`scripts/lib/agent-doctor.sh:245-286`) assert with substring `grep -q`, so they
are insensitive to added fields; the only strict whole-map equalities in the test
suite are on auth-error envelopes, not MCP results.

Tasks (Slices 1-2) are additive by the extension's own rule: a server MUST NOT
return a task to a client that did not declare the capability in that request's
`_meta`. So `terminal_wait_agent_state` keeps its 55s long-poll shape for every
current agent, and only Tasks-aware clients see `resultType: "task"`. The failure
mode to guard in review is a tool being migrated to task-*only* rather than
task-*optional*.

What is genuinely risky is not the protocol — it's the blast radius and the
rollout:

- **One module fronts all three servers.** `MCPEnvelope` is shared by preview,
  terminal, and artifact. A regression there takes out every agent's entire tool
  surface simultaneously, which is the opposite of the usual one-server-at-a-time
  failure. This argues for landing Slice 0 behind the contract test with all
  existing arms green, and for keeping the diff mechanical.
- **`MCPEnvelope` and `MCPSessions` are hot shared paths.** A
  `docs/in-progress.md` entry claiming them read-only will collide with other
  sessions' work; scope the claim narrowly and expect to rebase.
- **Repo-wide gates fail on other sessions' uncommitted diffs** on this shared
  checkout — attribute failures before fixing them.
- **Deploying restarts live MCP connections.** Agents mid-`wait_agent_state`
  lose the in-flight long poll and have to re-issue. Harmless (that's the
  documented contract today) but worth timing away from active delegation runs.

## Recommended entry point

Slice 0 + Slice 1 + Slice 2 as one campaign, in that order, with the contract
test as the gate at each step. Slice 0 alone is invisible to users; Slice 2 alone
is impossible without it.
