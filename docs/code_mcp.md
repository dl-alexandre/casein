# Code MCP

Structured, worktree-scoped code tools for headless workers. This is not a
tmux surface and does not replace Terminal MCP.

```
POST /api/code/mcp
```

Auth is the same bearer gate as the other Casein MCP servers
(`Authorization: Bearer $CASEIN_API_TOKEN`). Pre-scope with
`?workspace_id=<id>` to inject workspace identity. Streamable HTTP
`GET`/`DELETE` on the same path follow the existing MCP session contract.

## Why this exists

Terminal MCP is an interactive tmux contract. Headless workers need bounded
file, search, patch, and verifier primitives that return structured errors
instead of pane text.

## Tools

Every call requires `workspace_id` (injected when pre-scoped) and
`worktree_path` for the assigned attempt. Optional `task_id` / `attempt_id`
are stamped onto audit/activity.

| Tool | Mutates? | Params | Result |
|------|----------|--------|--------|
| `code_read` | no | `path`*, `start_line`, `end_line`, `max_bytes` | `{path, content, start_line, end_line, truncated, byte_truncated, range_truncated}` |
| `code_search` | no | `query`*, `path`, `glob`, `max_matches`, `max_bytes` | `{matches: [{path, line, text}], match_count, truncated}` |
| `code_apply_patch` | yes | `patch`*, `idempotency_key` | `{applied, already_applied, idempotent, paths, changes}` |
| `code_exec` | yes | `command_id`*, `extra_args`, `cwd`, `timeout_ms`, `max_output_bytes` | `{command_id, argv, cwd, exit_code, output, timed_out, output_truncated, cancelled, status}` |

`command_id` is a server-owned verifier: `compile`, `test`, `format`,
`precommit`, `assets.build`. There is no raw shell. Extra args must be
repository-relative paths with no flags or shell metacharacters.

## Limits

| Cap | Default | Max |
|-----|---------|-----|
| Read/search/exec output | 64 KiB | 256 KiB |
| Search matches | 50 | 200 |
| Exec timeout | 30s | 120s |
| Patch size | — | 512 KiB |

Truncation, timeout, and cancellation are always explicit booleans on the
result. A timed-out `code_exec` sets `timed_out: true` and `cancelled: true`
after killing the server-owned process.

## Path and worktree rules

Rejected before any filesystem or git call:

- absolute paths
- `..` traversal
- backslashes
- NUL bytes
- `.git` and other PathSafety ignore trees
- paths outside the assigned worktree (including symlink escape)

`worktree_path` must be the workspace checkout or a registered agent
worktree for that workspace. Another workspace's tree is
`worktree_not_assigned`.

## Policy and audit

Mutations go through existing Casein policy:

- `code_apply_patch` → `Policy.can_edit_file?/1`
- `code_exec` → `Policy.can_run_command?/1` with the allowlisted command id

Argv is resolved from `Casein.Commands` / `ExecCtl.Allowlist`. Patches are
parsed with `Casein.Proposals.UnifiedDiff` and applied only through
`Casein.ProposalApply.GitAdapter`.

Retrying an already-applied patch returns `applied: true`,
`already_applied: true`, `idempotent: true` instead of an error.

`MCPAudit.record_code/5` writes the activity feed for every call and a
durable audit row for `code_apply_patch` and `code_exec`.

## Errors

Stable `structuredContent.error` atoms include:

`workspace_not_found`, `workspace_scope_mismatch`, `worktree_path_required`,
`worktree_not_found`, `worktree_not_assigned`, `absolute_path`,
`outside_root`, `backslash_in_path`, `nul_in_path`, `path_not_allowed`,
`invalid_patch`, `invalid_path`, `patch_does_not_apply`, `not_allowed`,
`policy_denied`, `invalid_argument`, `too_large`.

## Example

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "code_read",
    "arguments": {
      "worktree_path": "/data/casein-agent-worktrees/wt-1",
      "path": "lib/hello.ex",
      "start_line": 1,
      "end_line": 40
    }
  }
}
```

On a pre-scoped endpoint, omit `workspace_id`. Keep Terminal MCP for
interactive OpenCode panes.

## Out of scope for this surface

`git_status`, `git_diff`, `task_wait`, and `task_cancel` remain follow-up
work on the parent epic. This issue ships the four code primitives plus the
MCP/auth/scope/audit wiring they need.
