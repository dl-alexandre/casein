# Snapshot: one verb, three meanings

> **Success criterion.** "Capture the visible state of a surface" is one action id behind
> one gate, and nothing else in the codebase is called *snapshot* unless it does that.

## Correction to the follow-on note in `agent-work-as-a-run.md`

That page closed by naming snapshot consolidation as "three implementations of one shared
verb." That is wrong, and the mistake matters: merging these would fuse unrelated
behaviour behind one name.

`snapshot` is a **homonym**. It currently spans three unrelated concepts:

| Concept | Where | What it does |
|---|---|---|
| **Capture a record of a surface** | `ghostty:snapshot`, `snapshot_all` (human)<br>`preview_tools/screenshot` (agent) | Writes a durable artifact of what a surface currently shows |
| **Mark a version** | `artifact_tools/snapshot` → `ArtifactProjects.snapshot/2` | *"Create an explicit Git version marker commit for an artifact project."* Tagged `mutation` |
| **Read current state** | `Terminals.Attachment.snapshot/1`, `Terminals.Session.snapshot/1`, `TmuxTopology.snapshot/2` | In-memory read of present state. Produces nothing durable |

Only the first row is a shared verb. The second is a git operation wearing the same word.
The third is a read.

## The one genuine shared verb

**Capture a durable record of what a surface currently shows.** Two implementations, two
entry points each:

- **Terminal** — `ghostty:snapshot` calls `Terminals.capture_ghostty_snapshot/2`, writes
  `<base>.html` + `.txt` + `.vt`, emits an `Audit` event with action
  `ghostty.raw_terminal_snapshot`, and pushes `ghostty:snapshot:captured` to the client.
  `snapshot_all` is the same over every pane.
- **Preview** — `preview_tools/screenshot`, described as *"Capture a screenshot artifact
  from the current preview page."*

This is one of the six human∩agent overlap verbs identified in the MCP-vs-palette
inventory, which makes it the natural **first test case** for "one action id, one gate,
several backends" — the structure agreed for the overlap set. It is a better first case
than the others because both sides already exist and neither is speculative.

## What differs today, and must be decided

These are the real design questions. They are not cosmetic; each one is a place where the
two implementations disagree about what capture *means*.

### Destination — does capture always produce an artifact?

Terminal capture writes files and pushes them to the client. Preview capture produces an
*artifact*. If capture is one verb, its output should be one kind of thing.

**Recommendation:** capture produces an artifact, uniformly. The terminal path already
produces artifact-shaped output (a named base plus format variants); what it lacks is
registration. This also gives captures a retention story and a place to be listed, which
files-plus-a-push does not.

### Audit altitude — the same split as runs

The terminal path emits a **domain** `Audit` event (`ghostty.raw_terminal_snapshot`, with
actor, target, and metadata). The preview path is covered by transport-level `MCPAudit`.

That is the identical altitude mismatch documented in `agent-work-as-a-run.md`: one path
records the *act*, the other records a *tool call*. A consolidated verb should emit one
domain event regardless of which surface invoked it, with transport audit remaining the
lower stream.

### Scope — is "all" a parameter or a verb?

`snapshot_all` is a separate handler from `ghostty:snapshot`. Under one action id, "all
panes" is a scope argument, not a second action — otherwise every future surface type
doubles the verb count.

### Naming and retention

Terminal captures are keyed by a generated `base`; artifacts have ids. Consolidation needs
one identity scheme, or captures cannot be listed, deduped, or expired together.

## What should be renamed, not merged

**`artifact_tools/snapshot` → a version-marker name** (`artifact_mark_version`,
`artifact_tag`, or similar). Behaviour unchanged; it is a good tool with a colliding name.
This is the highest-value rename because it is *agent-facing*: an agent choosing between
`artifact_snapshot` and `preview_screenshot` is choosing between a git commit and an image,
and the names do not say so.

**The internal reads** (`Attachment.snapshot/1`, `Session.snapshot/1`,
`TmuxTopology.snapshot/2`) are lower stakes — no external surface, no agent confusion — but
they cost comprehension every time someone greps for snapshot behaviour. Rename
opportunistically to `current_state/1` or `read/1`; not worth a dedicated change.

## Non-goals

- Do **not** merge the version marker into capture. Different concept, different tags
  (`mutation`), different consumers.
- Do **not** change what a terminal capture writes (`.html` / `.txt` / `.vt`) — that format
  set is deliberate.
- Do **not** add a gate. Capture is already permitted wherever it is reachable; this is
  consolidation, not new policy.
- Do **not** rename the internal reads as part of the consolidation change — it inflates the
  diff and buries the real change.

## Sequencing

Smaller than the runs page and independent of it, with one ordering note: the audit
altitude decision above should follow whatever `agent-work-as-a-run.md` settles, so capture
does not invent a second answer to the same question.

1. Rename `artifact_tools/snapshot` — standalone, immediately reduces agent confusion.
2. Unify capture behind one action id with terminal and preview backends, scope as an
   argument, artifact as the uniform destination.
3. One domain audit event for capture, regardless of entry point.

## Why this is worth doing at all

Not tidiness. Snapshot is the first of the six overlap verbs to get the shared-gate
treatment, so how it goes decides whether "one action id, one gate, several backends" is
a pattern worth applying to the other five — or whether the overlap really is thin enough
that each verb should stay bespoke. It is deliberately a test case.
