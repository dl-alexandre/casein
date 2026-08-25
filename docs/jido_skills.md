# Jido skills and OpenCode fallback

[#1017](https://github.com/dl-alexandre/casein/issues/1017) (parent
[#1012](https://github.com/dl-alexandre/casein/issues/1012)). Ports Casein
skills onto the headless Jido path and keeps OpenCode as an explicit fallback.

## Boundary

- **Does not change** the #1014 pod, #1015 action catalog, or #1016 projection
  contracts.
- **Does not implement** resource budgets ([#1018](https://github.com/dl-alexandre/casein/issues/1018));
  those live in [`jido_budgets.md`](jido_budgets.md).
- **Casein** remains authoritative for workspace, worktree, policy, audit,
  human input, and verification.
- **No visible pane.** Jido attempts are `headless: true` with no `pane_id`.

## Skills

`Casein.Agents.JidoSkills` loads `SKILL.md` from:

1. `priv/jido/skills` — reusable task skills (default coding set)
2. `.claude/skills` — repo/agent instructions, classified as `:runtime` when
   they drive tmux, Preview MCP, or other TUI surfaces

Frontmatter `kind: task | runtime` and `jido: supported | unsupported |
runtime_specific` win. Missing `kind` is inferred from the body. Each skill
lists the typed actions it needs; those names are mapped onto
`Casein.Agents.JidoActions.catalog/0`.

### Default coding set

| Skill | Actions | First Jido release |
|-------|---------|--------------------|
| `inspect` | `code_read`, `code_search` | supported |
| `patch` | `code_apply_patch` | supported |
| `approved-verify` | `code_exec` | supported |
| `human-input` | `request_clarification`, `request_human_input` | supported |
| `progress` | `report_progress`, `report_result`, `handoff_evidence` | supported |
| `representative-edit` | inspect + patch + verify + evidence | supported |
| `git-inspect` | `git_status`, `git_diff` | **not yet supported** |
| `task-control` | `task_wait`, `task_cancel` | **not yet supported** |

Unsupported skills fail with a machine-readable payload
(`error: :not_yet_supported` or `:runtime_specific`). They are not silently
approximated.

## Runtime selector

Manager MCP (`jido_admit` / `jido_status` / `jido_cancel` via
`Casein.Agents.JidoDelegate`) uses this selector. A disabled workspace or
`runtime: opencode` returns a `worker_launch` fallback receipt.

`JidoSkills.select/2` chooses `:jido`, `:opencode`, or a later explicit
fallback:

| Input | Result |
|-------|--------|
| `runtime: :opencode` | legacy OpenCode (`reason: :explicit_opencode`) |
| `runtime: :jido` and flag off | `{:error, %{error: :jido_disabled}}` |
| supported skill + flag on | Jido (`reason: :jido_default` or `:explicit_jido`) |
| unsupported skill + Jido | `{:error, %{error: :not_yet_supported}}` |
| flag off, no skill | OpenCode (`reason: :legacy_opencode`) |
| `mode: :shadow` / `:canary` | same selection, `shadow?` / `canary?` set; only one backend mutates |

Model/provider defaults: `CASEIN_JIDO_DEFAULT_MODEL` /
`:jido_default_model` (default `opencode/grok-4.6`) and
`:jido_default_provider` (`opencode`).

## Fallback

Provider, tool, or runtime failure produces an observable receipt:

```elixir
JidoSkills.fallback(prior_attempt, :provider_unavailable)
```

The receipt is recorded on `Activity` (`source: :jido_skills`,
`tool: "jido_fallback"`) with a reason code, the prior attempt id, and
completed `mutation_token`s. `JidoSkills.remaining_actions/2` drops those
tokens so OpenCode does not replay a mutation.

## Evidence

`JidoSkills.bind_attempt/1` records backend, skill name, skill version
(tree fingerprint), and the action-catalog digest. `evidence_status/1` is
`:stale` when either digest changes.

## Feature flags and rollback

| Switch | Effect |
|--------|--------|
| `CASEIN_JIDO_HEADLESS=1` / `:jido_headless` | Jido is eligible |
| `CASEIN_JIDO_HEADLESS_WORKSPACES` | those workspace ids only |
| flag off | OpenCode; typed Jido actions stay `legacy_opencode` |
| `runtime: :opencode` on select/admit | force OpenCode even when the flag is on |
| `CASEIN_JIDO_DEFAULT_MODEL` | model advertised on selections |

Rollback: unset `CASEIN_JIDO_HEADLESS`. Task/attempt/audit history stays.
OpenCode continues on Code MCP / Terminal MCP. Removing the Jido path later
requires the parity matrix below to be green **and** the #1018 resource
benchmark.

## Canary criteria

- `representative-edit` succeeds on Jido without a pane
- the same fixture on OpenCode matches outcome, changed paths, verification
  id, and audit identity (`workspace` / `task` / `attempt` / `backend`)
- unsupported skills fail closed
- a provider failure falls back once, without duplicating a mutation

## Parity matrix

`JidoSkills.parity_matrix/0` is the machine-readable copy of the table in
this doc. First-release gaps (`git`, `task_control`, TUI/runtime skills)
are named, not faked.
