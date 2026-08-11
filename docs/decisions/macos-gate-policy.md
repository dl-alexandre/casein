# ADR: macOS self-hosted lane gate policy (#866)

Status: **accepted (human decision locked 2026-08-11)**

Parent: [#866](https://github.com/dl-alexandre/casein/issues/866) —
"S8: gate policy for the macOS self-hosted lane"

Related: [#865](https://github.com/dl-alexandre/casein/issues/865) owns the
**EACCES / bundle-publish writability** fix on the runner. This ADR is **policy
only** — it does not chmod the box, patch packaging scripts, rename CI jobs, or
demote the lane.

Human decision (host fold 20260811, cascaded to fleet):

> The macOS gate **STAYS REQUIRED**. Not advisory. Host milcmini chmod was
> temporary. Durable fix = #865. #866 = gate policy + how AM interacts. No
> hand-patch around #848.

---

## 1. Decision

| Question | Answer |
|----------|--------|
| Is the macOS self-hosted package lane required? | **Yes — required** whenever the workflow runs for the PR (path filter hit). |
| May it be demoted to advisory to green unrelated PRs? | **No.** |
| Is there an escape hatch? | **Yes — labelled quarantine only** (§4). |
| Does quarantine hide the red? | **No.** The real build job stays red and reported. |
| Who fixes infra reds (EACCES, quota, runner down)? | **#865** and ops — not product PRs hand-patching around them. |
| May the CI job be renamed to "fix" policy? | **No.** See §3. |

---

## 2. When the lane is in scope

`.github/workflows/macos-desktop.yml` runs on `pull_request` / `push` when any
path matches its `paths:` filter (desktop native, menubar, desktop auth,
`mix.lock`, packaging scripts, the workflow itself, etc.).

- **In scope + red** → merge blocked by policy. Do not arm AM. Do not hand-patch
  product code to dodge the path filter.
- **Out of scope** → workflow does not run; Linux `gate` alone is the required
  branch-protection context (see AGENTS.md).
- **`mix.lock` bumps are in scope on purpose** — desktop packages the BEAM
  release. That is not a false path match (#848 class).

Path-filter changes are a separate design change; this ADR does not narrow them
to make reds go away.

---

## 3. Check name freeze (do not rename)

The self-hosted matrix job check name today is:

```text
Build and verify (macOS 26 arm64 (self-hosted))
```

That string is produced by:

```yaml
jobs:
  package-smoke:
    name: Build and verify (${{ matrix.name }})
```

with matrix entry name `macOS 26 arm64 (self-hosted)`.

**Required status checks (and humans reading the board) match BY JOB/CHECK
NAME.** Renaming or restructuring this job silently:

- detaches any future required-check binding, or
- makes the board look green because the familiar red name vanished —

both are the "demote the gate by accident" failure mode this decision forbids.

Rules:

1. **Do not rename** `package-smoke`, its `name:`, or the self-hosted matrix
   `name:` field in a policy PR.
2. **Do not** add `continue-on-error: true` on the package job or its verify
   steps.
3. Additive jobs are allowed only when coordinated with branch protection and
   SUP; #866 ships **without** a workflow restructure.
4. Static guard: `scripts/check-macos-gate-policy.sh` fails if the canonical
   name fragment or `package-smoke` disappears, or if `continue-on-error` appears.

Branch protection today requires Linux context **`gate` only**. Treating macOS
as required is a **fleet/AM/human policy** on top of that API surface until an
owner deliberately adds a macOS context — and any such add must use the
**existing** check name, not a rename.

---

## 4. Quarantine escape hatch

**Label:** `ci/macos-quarantine`

### When to use

- The macOS job is red for a **known infrastructure** reason (runner EACCES
  covered by #865, artifact quota after green verify, runner offline) **and**
- The PR does not need a green package to trust the merge **and**
- A human (owner / SUP) applies the label deliberately — **not** a worker
  default, **not** Dependabot self-service.

### What quarantine does

1. Documents on the PR (comment) why merge may proceed despite the red check.
2. SUP may arm AM **only** with that label present and Linux `gate` green.
3. The real check
   `Build and verify (macOS 26 arm64 (self-hosted))` is left at its true
   conclusion (**FAILURE** stays FAILURE on the checks list).
4. Removing the label restores "do not merge / do not arm AM" discipline.

### What quarantine must never do

- Skip or `continue-on-error` the real package job so the red disappears.
- Rename/delete the failed check run.
- Cancel the workflow to clear the UI.
- Substitute for landing #865.

A quarantined red that is **not visible** on the PR checks list is a policy
violation. Hiding trades one failure mode (unrelated PR stuck) for a worse one
(infra debt invisible).

### Label lifecycle

```text
human applies ci/macos-quarantine
  → comment on PR: why + link to #865 (or incident)
  → merge only if Linux `gate` green and review OK
  → remove label after merge (prefer remove; long-lived Dependabot branches
    may keep it only while #865 is open)
```

Create the label in the GitHub UI/API when first used (`ci/macos-quarantine`,
description: "SUP/owner: allow merge despite reported macOS red; red stays visible").

---

## 5. Auto-merge (AM) interaction

Facts about this repo (2026-08-11):

- `allow_auto_merge` is **on**.
- Branch protection required contexts: **`gate` only** (`strict=false`,
  `enforce_admins=false` — see AGENTS.md). Direct pushes to `master` still use
  the local pre-push gate.
- GitHub AM waits for **required** checks. Optional red checks do not cancel AM
  by themselves — that is exactly why fleet discipline must be stricter than the
  API default.

Policy (binding on fleet / SUP):

| Situation | AM allowed? |
|-----------|-------------|
| Linux `gate` red | **No** |
| macOS in scope, `Build and verify (macOS 26 arm64 (self-hosted))` red, no `ci/macos-quarantine` | **No** — do not arm AM |
| Same red, `ci/macos-quarantine` present, Linux `gate` green | **Yes only if** SUP/owner armed AM knowing quarantine is intentional |
| macOS not in scope (workflow did not run) | AM follows Linux `gate` only |
| macOS check green | AM follows Linux `gate` only |

Fleet rule (unchanged): **workers never arm AM**. Report
`WORKER %pane -> MGR: issue=#… PR=#… gate=…`. SUP arms when appropriate.

Do **not** ask "arm-AM-when-green" in chat. Do **not** treat a temporary
milcmini `chmod` as durable green.

---

## 6. Relationship to #848 / #865

- **#848** (and similar lockfile bumps) correctly trigger macOS because
  `mix.lock` is in the path filter. That is not a false path match.
- Pressure to hand-edit product code so the macOS job is skipped is **forbidden**.
- **#865** makes the grok bundle publish path writable and asserted on the
  runner. Policy here only stops the wrong response (demote / hide / rename /
  patch).

---

## 7. Implementation map (#866 ships these)

| Piece | Location |
|-------|----------|
| Policy (this doc) | `docs/decisions/macos-gate-policy.md` |
| Static guard (name freeze + no continue-on-error + doc) | `scripts/check-macos-gate-policy.sh` |
| Hermetic test | `test/scripts/check_macos_gate_policy_test.exs` |
| Fleet pointer | AGENTS.md |

**Not in #866:** edits to `.github/workflows/macos-desktop.yml` job names or
structure (SUP hard caution while other PRs are in flight).

---

## 8. Explicit non-goals

- Demoting macOS to advisory.
- Renaming `Build and verify (macOS 26 arm64 (self-hosted))`.
- Expanding or narrowing the desktop `paths:` filter (separate change).
- Fixing EACCES / quota / runner images (#865 / ops).
- Windows desktop policy (mirror later if needed).
- Renaming the Linux `gate` job.

---

## 9. References

- https://github.com/dl-alexandre/casein/issues/866
- https://github.com/dl-alexandre/casein/issues/865
- https://github.com/dl-alexandre/casein/issues/848
- `.github/workflows/macos-desktop.yml` (read-only for this ADR)
- `.github/workflows/pr-gate.yml` (Linux `gate`)
- `docs/desktop/macos_release_evidence.md`
- AGENTS.md — branch protection / AM / self-hosted topology
