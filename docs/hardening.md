# DevIDE Hardening Checklist

This checklist keeps shared development moving while protecting users brought
onto the same DevIDE deployment.

## Boundaries

- User-facing workspaces must run from a known-good commit or release.
- Experimental work should happen on branches or separate workspaces.
- Every terminal, preview, and artifact MCP call must be workspace-scoped.
  Pre-scoped MCP URLs inject `workspace_id` when omitted and reject explicit
  overrides.
- Session-scoped preview tools must reject sessions owned by a different
  pre-scoped workspace.
- Workspace-scoped API tokens can only access `/api/workspaces/:id/...` for
  their workspace or MCP endpoints scoped to that workspace.
- Terminal MCP mutation should target an explicit agent pane or the
  `agent_pair` marker path, not the operator pane.

## Permissions

- Workspace owners may manage their workspace safety mode unless the mode is
  pinned by config.
- Admin/operator identities may manage operational controls across workspaces.
- Viewers should not see controls the server policy would reject.
- Proposal apply (a human reviewing and applying an agent-authored diff)
  requires workspace operator + `:manual` mode (`Policy.can_apply_proposal?/1`,
  `DevIDE.ProposalApply`).
- Autonomous agent write (a review-agent run self-applying its own proposal
  with no per-change human click) is the reviewed unlock flow: requires
  `:manual` mode plus an explicit, time-boxed, human-granted unlock
  (`Workspaces.grant_agent_write_unlock/3`), gated again by a deployment-wide
  kill switch (`DevIDE.Proposals.AutoApply`, off by default) and a content
  veto (diffs touching `test/` are never auto-applied). Revoking the unlock
  (`Policy.can_revoke_agent_write_unlock?/1`) has no mode/isolation gate —
  it must always be reachable.

## Deploy Safety

- Use the release deploy path; do not hand-edit `/opt/devide/release`.
- Keep deploy scripts and release overlays in git before activation.
- Graceful drain should warn connected LiveViews before shutdown and leave
  tmux sessions outside the release artifact.
- `/api/deploy_status` must pass before traffic handoff is considered healthy.
- `scripts/deploy-local.sh` runs `scripts/hardening-audit.sh --live` after
  activation unless `DEVIDE_SKIP_HARDENING_AUDIT=1` is set.

## Recovery

- Keep rollback, cleanup, deploy handoff, and agent pairing smoke scripts
  runnable from the checkout.
- Source `.devbox-agent.env` before live MCP checks; never commit it.
- Audit terminal/preview/artifact MCP mutations so operators can distinguish human and
  agent actions.
- Use `scripts/workspace-doctor.sh <workspace_id>` to collect deploy status,
  workspace status/topology/audit, MCP sessions, and tmux session hints.

## Durable tmux sessions (FP-2)

Session idle GC is **opt-in**. Leave `DEV_IDE_TMUX_IDLE_SECONDS` unset in prod
(the runtime default is `nil` — `TmuxJanitor` never kills unsubscribed sessions).
Only set a positive value when you explicitly want idle tmux reclamation.

## Workspace-Scoped Tokens

Keep the global admin bearer in `/etc/devide/devide.env` as `DEV_IDE_API_TOKEN`.
`setup-devbox-agent-pairing.sh` registers per-workspace tokens and writes the
scoped bearer into `.devbox-agent.env` as `DEV_IDE_API_TOKEN` (admin preserved as
`DEV_IDE_ADMIN_API_TOKEN`). Manual addition also works with:

```bash
export DEV_IDE_WORKSPACE_API_TOKENS='{"token-for-workspace-a":"workspace-a"}'
```

The value is a JSON object mapping bearer token to one workspace id or a list of
workspace ids. A workspace-scoped token may omit `workspace_id` on MCP calls; the
server injects the token's workspace. Explicitly passing a different workspace is
rejected before tool dispatch.

## Audit Command

Run local checks:

```bash
scripts/hardening-audit.sh
```

Run local checks plus live devbox smoke checks:

```bash
source .devbox-agent.env
scripts/hardening-audit.sh --live
```

Collect a workspace recovery bundle:

```bash
source .devbox-agent.env
scripts/workspace-doctor.sh "$DEVIDE_WORKSPACE_ID"
```
