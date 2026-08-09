# Boundary statements for preview and artifacts

> **The exercise.** `docs/desktop/platform_architecture.md` contains one sentence that makes
> the whole desktop host legible:
>
> > The desktop host owns installation, startup, windowing, updates, and crash recovery;
> > **it does not become a second application backend.**
>
> Preview and artifacts have no equivalent sentence. This page writes them, and forces the
> decisions that writing them exposes.

## A correction, first

An earlier read of these subsystems compared agent tool counts to human event counts —
preview at 39 agent tool modules against 14 human events, artifacts at 9 against 4 — and
concluded the human surface was starved.

That measurement was wrong for preview. **The preview is an `iframe`**
(`iframe[data-preview-iframe]`), and `preview-pane:enter` sets a class whose only CSS effect
is a 2px indicator strip. The human interacts with the page directly. They have no
`preview_click` tool because they have a pointer.

An agent needs 39 tools precisely because it has neither hands nor eyes. Counting them
against a human's events measures the gap between direct manipulation and remote control,
not a gap in the product.

## What survives that correction

Two asymmetries are real, and neither is about interaction.

**Preview analysis is agent-only.** `compare_snapshots`, `record_start` / `record_stop`,
`playback_open`, and `report_errors` are not things hands help with. A human in the cockpit
cannot diff two snapshots, replay a recorded session, or read collected console errors —
capabilities an agent has and uses.

**Artifact authoring is agent-only.** Human events are `artifact:inspect`, `open`,
`refresh`, `serve`. There is no create, update, or retire. Artifact projects are generated,
Git-worktree-backed, and registered through `Casein.Runtimes` — explicitly an MVP that
reuses the runtime and preview pipeline rather than adding persistence.

So the honest shape is not *"agents can do more"*. It is: **agents can analyse and author;
humans can only look.**

## Proposed sentence — preview

> The preview owns showing a running surface and letting a human interact with it directly.
> It does not become a browser-automation UI: the agent's driving tools have no human
> counterpart because the human has a pointer. **Analysis that hands cannot perform —
> snapshot comparison, recording and playback, collected errors — reaches the human as
> results to review, not as controls to operate.**

The load-bearing clause is the last one, and it is a decision rather than a description.
Today those analyses have no human surface at all. Three options:

| Option | Consequence |
|---|---|
| **Results, not controls** (proposed) | An agent that compares snapshots or records a session surfaces the outcome — into the artifact gallery, or a run, or an inspector. The human never operates the tooling. Smallest surface; keeps the cockpit a supervision surface. |
| Full parity | The human gets record/compare/replay controls in the preview pane. Largest build, and duplicates capability the human's own browser devtools already provide. |
| Leave as-is | Analysis stays invisible to the human unless an agent chooses to mention it in prose. This is the status quo, and it is the one option that is clearly wrong — the capability exists and its output is unreachable. |

**Recommendation: results, not controls.** It matches how the human already relates to
preview (watch a surface, interact when needed) and it needs a destination rather than a UI —
which the artifact and run models already provide.

## Proposed sentence — artifacts

> An artifact project is **agent-authored and human-reviewed**. The cockpit owns viewing,
> serving, inspecting, and verifying artifacts; **it does not become an artifact editor.**
> A human who wants to change an artifact changes the thing that generates it.

This one is close to describing current behaviour, which is a good sign — the asymmetry
looks deliberate rather than accidental. What it changes is that the absence of a create
button becomes a stated position rather than a missing feature, and future work stops
drifting toward an editor.

The decision it forces: **is `artifact:serve` review, or is it publishing?** Serving makes an
artifact reachable. If that is a publishing act, it deserves the treatment publishing gets
elsewhere in the product — a policy gate and an audit event — rather than sitting alongside
`inspect` and `refresh` as though it were a view operation. Worth checking before the
sentence is adopted.

## Why sentences rather than issues

Both subsystems have working code and no stated purpose. Every future question about them —
should the human get this control, should that capability have a surface — reopens the same
argument because nothing settles it.

The desktop host does not have this problem, and the only difference is one sentence written
down. That is a cheap intervention with a long payoff, and it is why this is a page rather
than a backlog.

## Non-goals

- Not proposing new preview or artifact features. The two sentences may *close* questions;
  they should not open a build.
- Not touching the agent tool surface. That is the six-verb overlap work, tracked separately.
- Not a rewrite of `platform_architecture.md` — it is the model here, not the subject.

## Follow-on

If the preview sentence is adopted as written, one issue falls out of it: give agent-run
analysis a destination. That is a small piece of work and it is the only concrete
consequence of this page.
