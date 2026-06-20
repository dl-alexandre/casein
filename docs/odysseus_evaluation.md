# Odysseus Evaluation — Replace, Complement, or Integrate?

> Context: Considering swapping (parts of) DevIDE for [pewdiepie-archdaemon/odysseus](https://github.com/pewdiepie-archdaemon/odysseus), a popular self-hosted AI workspace (FastAPI + vanilla JS PWA).

This document compares the two projects against DevIDE's stated goals, invariants, and product boundary. It is the place for the decision and any integration plan.

## One-sentence positioning

- **DevIDE**: A safety-first, auditable, durable **workspace runtime authority** (the engine). Humans *and* agents are clients of the same governed contract. Explicit non-goal: "Not an agent framework."
- **Odysseus**: A delightful, local-first **AI chat + autonomous agent + personal workspace app** (the brain + cockpit). Built as the self-hosted "ChatGPT/Claude UI" experience with real tool-using agents.

They are adjacent layers, not direct substitutes.

## Side-by-side

| Dimension                  | DevIDE (this project)                                                                 | Odysseus (pewdiepie-archdaemon/odysseus)                                                                 |
|----------------------------|---------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------|
| **Primary goal**           | Governed execution substrate for dev workspaces (local/remote/fleet). Every action is policy-checked, audited, replayable, lease-safe. | Self-hosted AI workspace that feels like the web UIs: chat, autonomous agents, documents, memory, research. |
| **Agent philosophy**       | Agents are *untrusted clients* of the runtime. Same API surface as a human operator. "Agent write" is explicitly locked in most modes. | Agents are first-class citizens *inside* the app. Full autonomous loop (opencode + MCP tools) with shell, files, browser, memory, skills. |
| **Safety / governance**    | Extremely strong (allowlist argv only, policy decisions + audit events, claim/lease protocol, full dossiers, workspace modes, redaction, no arbitrary execution). FP-1..FP-10 invariants. | Tool-level permissions (per-user privileges, admin gates for shell/MCP). Agent can do real damage if given broad tools; security notes emphasize treating it like an admin console. |
| **Terminal / sessions**    | Core product: durable tmux (or SSH tmux) sessions via erlexec + Ghostty NIF, Phoenix Channels, replay on reconnect, survive server restarts. | Agent has a "shell" tool. No first-class durable multi-pane tmux story or browser-attached PTY for the human operator. |
| **Execution model**        | Runners poll/claim/lease/report with full protocol v1. Immediate local path + durable fleet path. Evidence required. | Direct execution in the Odysseus process or via MCP servers (Playwright, etc.). Background model serving via Cookbook + tmux. |
| **Data model & durability**| Postgres (prod) or memory adapters. Assignments, ProgressReports, Audit.Events, History, Runtimes, Workspaces — append-only where it matters. | SQLite (`data/app.db`) for sessions/messages/docs + ChromaDB for vector memory + JSON files. All local-first. |
| **Stack**                  | Elixir/OTP + Phoenix 1.8 + Ecto + LiveView + heavy native (erlexec, zigler/ghostty). Complex but excellent supervision/concurrency. | Python 3.11+ + FastAPI + vanilla modular JS (static/ + js/) + PWA. Simple, hackable, one-person maintainable. |
| **LLM / models**           | None built-in. You bring external runtimes (or use via agents talking to the API). | Excellent: Cookbook (hardware scan + recommend + download + serve with vLLM/llama.cpp), many providers (Ollama, OpenAI, Anthropic, local), blind compare, etc. |
| **Memory / long context**  | Operational history + audit + dossiers (great for post-mortems and review). No user-level vector memory or "skills". | First-class: Chroma + fastembed (ONNX), persistent memory + skills that evolve, import/export. Agent gets better over time. |
| **UI**                     | LiveView workspace picker + terminal surface + evidence drawer + fleet views + panes. Heavy custom terminal work. Many ui-iterations/ studies. | Polished, responsive PWA (mobile-first friendly). Chat, documents (multi-tab editor), deep research reports, notes/tasks/calendar/email, settings, themes. Feels like a real product. |
| **MCP / tools**            | Detects agent markers (`.opencode`, `.fff`, browser artifacts). Serves Tidewave MCP endpoint. "Agent" capabilities are observed, never driven by DevIDE itself. | Built around MCP. Auto-registers built-in servers (Playwright browser for vision/screenshots/navigation). Easy to add more. Agent loop uses tools via MCP. |
| **Fleet / multi-host**     | Removed — DevIDE collapsed to a single-runtime cockpit; multi-host placement and runner orchestration are gone. | Single-instance focus (with remote model servers possible). No equivalent of a fleet coordinator. |
| **Auth & multi-user**      | Bearer tokens for API/runner, session-based for browser (with current user scoping in LiveViews). | Built-in auth (admin + users), 2FA option, per-user privileges (non-admins get restricted shell/file access). |
| **Deployment**             | Docker + Postgres + optional runner processes. Detailed deploy/runbooks/audits. | Docker Compose (recommended) bundles Odysseus + Chroma + SearXNG + ntfy. Native scripts for macOS/Windows. Very easy local start. |
| **Maturity / scope**       | v0.1 RC territory for the runtime contract. Deep protocol docs, state machines, failure taxonomy, audits. Narrow but deep. | "vers. 1.0", very feature-rich (chat/agent/research/docs/memory/email/calendar/notes + extras). Broader surface. 49k+ GitHub stars. |
| **Explicit non-goals**     | Not a code editor, not generic AI chat, not an agent framework, not a dashboard. | Not trying to be a fleet runtime or governed execution authority. |

## Overlaps (real but shallow)

- Both care about workspaces on disk that contain code + agent artifacts.
- Both have some awareness of "agent stuff" in the fs (DevIDE detects `.fff`/opencode/browser dirs; Odysseus has its own agent runtime).
- Both like MCP (DevIDE exposes Tidewave; Odysseus is MCP-native for tools).
- Both want durable, local-first operation with auditability (different flavors).
- Shell/file access is a thing in both (very different trust models).

## Gaps each fills for the other

**What Odysseus gives you that DevIDE deliberately does not:**
- Turnkey autonomous agent that can plan + use tools + remember + iterate without you in the loop.
- Beautiful chat + document + research UX out of the box.
- Local model lifecycle (Cookbook) and easy multi-provider switching.
- Vector memory + skills that persist across sessions.
- Mobile PWA that just works.
- Much lower barrier to "I have an AI that can do stuff for me today."

**What DevIDE gives you that Odysseus does not (and would be expensive to recreate):**
- Hard guarantee that an agent (or compromised session) cannot run arbitrary commands.
- Full evidence trail + replay for anything that *did* run (dossiers).
- Durable human-usable terminal sessions that survive disconnects, server restarts, and handoff.
- Fleet-scale runner orchestration with leasing, capability matching, drain, etc.
- The "runtime is the product, cockpit is a client" separation (FP-1 to FP-10).
- Battle-tested allowlist + policy + mode system designed exactly for delegated work.

## Recommendation

**Do not replace DevIDE with Odysseus.**

Replacing would mean discarding the core value proposition that the entire docs/ tree, state machines, protocol, audits, and invariants are built around: *a trustworthy execution authority that agents can be clients of, rather than an agent that happens to have a shell.*

The two projects are **complementary layers**:

```
Human or High-level Planner (a coordinator)
          │
          ▼
Odysseus (or similar) — chat, memory, research, agent loop, nice UI, local models
          │  (uses tools)
          ▼
DevIDE (governed runtime) — policy, durable tmux, audit, evidence
          │
          ▼
Workspaces (code, git, services, real shells via tmux)
```

This is almost exactly the mental model already described in `docs/product.md` §7 and §10 (a planner/scheduler on top of one or more DevIDE authorities; agents as first-class clients of the runtime contract).

## Integration options (ranked)

1. **Best: DevIDE as a high-trust MCP tool for Odysseus (or any agent)**
   - Implement a small MCP server (stdio or streamable HTTP) that exposes governed DevIDE actions as tools:
     - `devide_list_workspaces`
     - `devide_get_status(workspace_id)`
     - `devide_submit_governed_run(workspace_id, command_id, args?)`  (the safe action path)
     - `devide_read_recent_output(workspace_id, run_id?)`
     - `devide_get_audit(workspace_id)`
     - `devide_attach_terminal(...)` (read buffer / stream events)
   - Odysseus's agent (via its opencode/MCP machinery) or a custom skill can then "use the DevIDE workspace" when it needs safe, auditable, durable execution.
   - The agent gets power without the host getting pwned.
   - This is a natural extension of the existing `DevIDE.Agents` detection + Tidewave MCP surface.

2. **Run them side-by-side for different concerns**
   - Odysseus for personal research, writing, broad agent tasks, local model playground, documents, email/calendar.
   - DevIDE for "I need a real durable terminal in a real workspace with policy and fleet runners."
   - Share workspaces on disk where it makes sense.

3. **Minimal: Borrow UX/ideas into the existing Phoenix surface**
   - Add a richer chat/agent pane behind capability gates (only when an agent runtime is detected).
   - Improve the "transcripts" and review commands surfaces already in `DevIDE.Agents`.
   - But this duplicates a lot of what Odysseus already does well.

4. **Nuclear: Sunset the runtime and move execution authority into Odysseus**
   - Only consider if the safety/fleet/durable-terminal requirements turn out to be over-engineered for the actual use cases.
   - Would require reimplementing (or wrapping) large parts of the current protocol, tmux durability, policy, and runner substrate inside the Python stack. High cost, loss of BEAM advantages.

## Current DevIDE hooks that already point at this world

- `lib/dev_ide/agents.ex` + `LocalAdapter` — explicitly detects opencode, fff, browser artifacts, Tidewave.
- Tidewave MCP endpoint (when the dep is present).
- "agent write locked" modes and the whole proposal/approval machinery.
- DevIDE's read/submit API surface is designed for a higher-level coordinator/planner to drive work.
- `docs/product.md` already says agents are first-class clients.

The "fff" MCP tool visible in the current Grok session is a delightful coincidence.

## Proposed immediate next steps

- [x] Prototype a `devide_mcp` server (Python, using the `mcp_servers/` layout that Odysseus expects for stdio MCP servers). Expose list/get + the safe `devide_run_command` surface. → See `mcp_servers/devide_server.py` + `mcp_servers/README.md`.
- [ ] Stand up Odysseus (Docker or native) in a sibling directory and do a 1–2 day dogfood to feel the agent loop + UI.
- [ ] Register the devide MCP server inside a running Odysseus (Settings) and verify the agent can discover + call `devide_list_workspaces`, `devide_get_status`, `devide_run_command` (e.g. `opencode` or `test`), then observe via audit/status.
- [ ] Update `docs/product.md` / architecture if the integration changes any invariants or adds new capability gates.
- [ ] Decide: "Odysseus (or equivalent) is the daily AI driver + memory/research surface; DevIDE is the execution backend it can choose to use for serious, governed, durable workspace work."

## Current prototype status (mcp_servers/devide_server.py)

A complete first-cut stdio MCP server exists and follows the exact patterns used by Odysseus's own built-in servers (`memory_server.py`, `rag_server.py`, etc.).

It requires only `mcp` + `httpx` and two environment variables. All seven tools are implemented and defensively call the existing DevIDE read + POST /runs surfaces.

The server never bypasses policy or the allowlist. 

See `mcp_servers/README.md` for registration instructions and safety notes.

Next concrete engineering step is usually "get Odysseus running + wire the MCP server".

## Prototype files (first integration cut)

- `mcp_servers/devide_server.py` — the MCP stdio server. Self-contained, follows Odysseus's server patterns exactly.
- `mcp_servers/README.md` — how to run it, required env vars, how to register it from Odysseus, and safety notes.

These live at the root of the DevIDE checkout so they are easy to reference or copy into an Odysseus `mcp_servers/` directory (or run from anywhere via absolute path + PYTHONPATH if you want to import more context later).

## References

- DevIDE: `docs/product.md`, `docs/architecture.md`, `lib/dev_ide/agents.ex`, `lib/dev_ide_web/router.ex` (API surface), Tidewave integration.
- Odysseus: README, `src/agent_loop.py` (inferred from structure), `mcp_servers/`, architecture section in README, THREAT_MODEL.md, SECURITY.md.

Status: Evaluation complete + first prototype delivered. Awaiting user direction on standing up Odysseus + wiring test.
