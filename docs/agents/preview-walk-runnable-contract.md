# Preview walk-runnable surface contract (S12 / Mira)

**Audience:** Mira (or any external product worker) that must run a **budgeted
product UI walk** against a Casein-hosted preview.  
**Owner of the walk:** the product worker (Mira).  
**Owner of this contract:** Casein Preview MCP + surface discovery.

Casein **does not** run the soak. Casein **does not** implement Facility parity.
This document stabilizes the **shape** a Mira worker must call so walks are
repeatable, fail-closed, and operator-visible when claimed.

Related skill (product manifests, not Casein soak): `preview-ui-walk`.  
Wire reference: [`docs/preview_mcp.md`](../preview_mcp.md).

---

## 1. Roles (non-negotiable)

| Layer | Owns | Does **not** own |
|-------|------|------------------|
| **Casein Preview MCP** | Surface discovery, open, visibility fields, observe/screenshot evidence tools | Product routes, login, soak budget, Facility parity |
| **Product repo** | `.casein/preview-walks/*.json` manifests, base URL, env checks | Casein MCP protocol |
| **Mira worker** | Pick surface → open → walk steps → evidence → report | Hidden subagents; claiming “visible” without fields |

If no product manifest exists, Mira authors one in the **product** checkout under
`.casein/` — never under Casein’s skill tree as product data.

---

## 2. Surface discovery (open contract)

### 2.1 List

```text
preview_surfaces { workspace_id }
→ { surfaces: [ surface_row, ... ], next_tool?, next_arguments? }
```

Each `surface_row` (from `Casein.Agents.PreviewTools.SurfaceDiscovery`) includes
at least:

| Field | Meaning |
|-------|---------|
| `name` | Surface id (e.g. `"app"`, `"localhost:41050"`, manager label) |
| `url` | Absolute URL Casein would open |
| `port` | Integer loopback port when known; may be null on pure public URLs |
| `source` | `"manager"` \| `"runtime"` \| `"terminal"` \| … |
| `server_active` | `false` only when loopback probe saw **dead**; else true |
| `server_status.liveness` | `"alive"` \| `"dead"` \| `"unprobed"` |
| `pane_registered` | Live preview pane registration exists for this origin |
| `operator_visible` | **True only when** browser loaded proof exists (see §3) |
| `browser_loaded` | Fresh browser-loaded visibility event |
| `browser_loaded_at` | ISO timestamp when known |
| `operator_visible_state` | Diagnostic string (`"browser_loaded"`, `"stale"`, …) |
| `pane_id` | Tmux preview pane id when registered |
| `tmux_session` / `runtime_id` | Placement / ownership hints |

**Classifier (pure, optional):** `Casein.Agents.PreviewTools.SurfaceDiscovery.classify_walk_runnable/1`
on a surface row → `{:walk_ready, meta}` \| `{:not_ready, reason}`.  
`reason: :unknown_observation` means “could not classify” — **never** treat as ready
(same discipline as AgentLiveness: unknown ≠ quiet/ready).

### 2.2 Pick a surface for open

Fail-closed rules for **opening** (not yet “operator can see it”):

1. Prefer `server_active == true`.
2. Skip `server_status.liveness == "dead"` (stale runtime registration).
3. Public / manager URLs often report `liveness: "unprobed"` — that is **openable**,
   not “unknown dead”.
4. Prefer workspace-declared `ports.http` or runtime-owned ports from
   `preview_ensure_server_here` over hand-picked loopback ports (hand-picked ports
   only stay authorized while a live pane registration exists; after Casein
   restart they refuse until re-registered).
5. For one-v3-dev class targets, the surface `url` / manager app URL is the
   contract; do not invent a second base URL.

### 2.3 Targeting one-v3-dev / PHX_HOST class hosts

| Signal | Use |
|--------|-----|
| Workspace manager / app surface from `preview_surfaces` | Canonical open target when Casein already knows the product URL |
| Product env `PHX_HOST` / `PHX_URL` / deploy host | Product-side base for **manifest** paths only; still open through Casein preview when the walk must be operator-visible |
| Preview own-origin (`pv-<port>-<workspace>.…`) | What the iframe actually loads after open — do not confuse with the product’s public login host |

Mira must not bypass Preview MCP with a raw browser against prod unless the
product workflow explicitly documents an off-Casein path (out of this contract).

---

## 3. Open path

```text
preview_open {
  workspace_id,          # required unless MCP URL is pre-scoped
  mode: "app" | "localhost" | "here",
  surface?,              # app mode: surface name from preview_surfaces
  port?,                 # localhost mode
  tmux_session?,         # here mode / session-scoped MCP injects this
  runtime_id?,           # pin a runtime-owned surface
  storage_profile?       # ephemeral | workspace | profile
}
→ { session_id, pane_id?, operator_visible?, preview_open_state?, … }
```

| `mode` | When |
|--------|------|
| `app` | Default. Named workspace/manager surface. |
| `localhost` | Specific loopback `port` (must be owned/declared or live-registered). |
| `here` | App surface beside the calling agent (`tmux_session` required; session-scoped MCP injects it). |

Deprecated aliases still work: `preview_open_app`, `preview_open_localhost`,
`preview_open_here`, `preview_open_current_workspace`. Prefer `preview_open`.

Preflight: dead localhost and hard HTTP failures **open no pane**. Treat open
errors as not walk-ready; do not invent a visible session.

---

## 4. Visibility gate (fail closed)

**Do not claim the operator can see the preview** unless **both** are true:

```text
operator_visible == true  AND  browser_loaded == true
```

Sources (same underlying visibility model — do not invent a parallel one):

| Call | Fields |
|------|--------|
| `preview_surfaces` | Per-row `operator_visible`, `browser_loaded`, `operator_visible_state`, `visibility` |
| Open / observe responses | `operator_visible`, `preview_open_state` (`"visible"` \| `"not_visible"` \| …), diagnostics |
| `preview_observe_pane` | Pane-backed visibility; use when a `pane_id` already exists |

Fail-closed rules:

1. Missing either field → **not visible** (unknown observation ≠ visible).
2. `operator_visible_state` of `"stale"` / non-`browser_loaded` → **not visible**.
3. `pane_registered == true` alone is **not** enough (registration ≠ loaded iframe).
4. `preview_open_state != "visible"` → do not tell the human the preview is up.
5. On not-visible: call `preview_observe_pane` (or re-list surfaces); follow
   `agent_next_action` when present. Never report calm success.

Pure check: `SurfaceDiscovery.operator_visible?/1` on a surface or observe map.

---

## 5. Mira-owned walk loop

Casein supplies tools; **Mira owns the loop and budget**.

```text
1. preview_surfaces
2. classify / pick openable surface (server_active; not dead)
3. preview_open (mode + surface/port)
4. Confirm visibility (§4) before claiming operator-visible
5. For each walk step (product manifest or Mira plan):
     a. preview_navigate / preview_click / preview_type / preview_press
        (prefer element_id from preview_elements after preview_observe_live)
     b. Evidence (§6)
6. Optional: artifact_publish / product report
7. preview_close when finished (or leave pane if operator is reviewing)
```

Product-side alternative: drive `preview-ui-walk` manifests under the product
repo’s `.casein/preview-walks/` with Casein MCP already paired. That skill walks
**product** UIs; it does not replace this contract and does not run inside Casein
as a soak service.

**Out of scope for Casein:** soak runner process, Facility parity suites,
hidden subagent walks, dual-stack MCP default edits.

---

## 6. Evidence capture sequence (required after steps)

After each material step (or at page boundaries), Mira must capture evidence via
Preview MCP — not “I looked at the pane”:

| Order | Tool | Produces |
|-------|------|----------|
| 1 | `preview_observe` | Fast static HTML / URL snapshot (`session_id`) |
| 2 | `preview_observe_live` | Hydrated DOM + console/network errors |
| 3 | `preview_report_errors` | Structured console + network error lists |
| 4 | `preview_screenshot` | Screenshot **artifact path** (durable under preview artifacts) |
| 5 | `preview_observe_pane` | When working from an existing `pane_id` (operator pane) |

Optional:

- `preview_record_start` / `preview_record_stop` → `.webm` artifact + playback pane
- Artifact MCP `artifact_create` / update for a bundled Mira report (login-gated
  public URL when published)

Minimum bar for a step that claims pass:

1. `session_id` (or `pane_id`) cited  
2. At least one of observe / observe_live  
3. Screenshot artifact path **or** explicit record artifact  
4. Errors list inspected (`preview_report_errors` or observe_live errors)  
5. Visibility fields if the claim is “operator saw it”

---

## 7. Env notes (one-v3-dev class)

| Variable / fact | Note |
|-----------------|------|
| `CASEIN_API_TOKEN` + Preview MCP URL | Workspace-scoped bearer; required for tools/call |
| `CASEIN_WORKSPACE_ID` | Pass on every call when MCP is not pre-scoped |
| Product `PHX_HOST` / base URL | Manifest / product routing only |
| Preview origin | Own-origin host (`pv-…`), not a path prefix under Casein |
| Auth | oauth2-proxy then workspace+port access — signed-in ≠ authorized for every port |
| Runtime ports | Prefer `preview_ensure_server_here` so the port stays owned across Casein restart |

---

## 8. Explicit non-goals

- Casein **worker as soak runner** (no fleet soak job inside Casein for Mira S12)
- **Facility parity** work or Facility-specific walk ownership in this repo
- Replacing product `.casein/preview-walks/*` with Casein-owned route lists
- CPU/idle heuristics; naive git unpushed checks; parallel visibility models

---

## 9. Code map

| Module / doc | Role |
|--------------|------|
| `Casein.Agents.PreviewTools.SurfaceDiscovery` | `preview_surfaces` payload + `classify_walk_runnable/1` + `operator_visible?/1` |
| `Casein.Agents.PreviewTools.ControlSession.Visibility` | Browser-loaded / operator visibility events |
| `docs/preview_mcp.md` | Full Preview MCP tool flow |
| `.claude/skills/preview-ui-walk` | Product walk **engine**; manifests stay in product repos |
| `docs/agents/examples/s12-preview-walk-shape.json` | Checklist shape for Mira planners |

Issue: #855.
