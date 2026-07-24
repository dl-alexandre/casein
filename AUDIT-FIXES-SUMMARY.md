# Audit fixes summary (Tier A)

Branch: `agent/grok/audit-fixes-20260709190654`  
Worktree off `master`; **not pushed**, no PR opened.

## Items

### 1. Fix N+1 on "mark all read" — **done**
- Added `DevIDE.Notifications.mark_all_read/1` using a single `Repo.update_all` for unread+unresolved rows.
- Drawer `notifications:mark_all_read` calls it once (no list+per-row loop).
- Test in `test/casein/notifications_test.exs` covers count, read-only targeting, resolved untouched, other users untouched.
- Broadcasts one `{:notification_updated, :mark_all_read}` for LiveView badge/list refresh.

### 2. Notifications composite index — **done**
- Migration `priv/repo/migrations/20260709192000_add_notifications_user_dedupe_index.exs`
- Index on `[:user_id, :dedupe_key, "inserted_at desc"]` for `recent_duplicate/3`.
- Applied via `mix ecto.migrate` in this worktree.

### 3. ETS concurrency flags — **done**
Added `read_concurrency: true, write_concurrency: true` to:
- `lib/casein/file_panes.ex`
- `lib/casein/preview_panes.ex`
- `lib/casein_web/channels/terminal_channel.ex`
- `lib/casein/terminals/workspace_access_cache.ex`

### 4. File-tree assign leak on collapse — **done**
- `tree:toggle` collapse now drops all assign keys under `path <> "/"` via `drop_tree_descendants/2`.
- Test asserts expanding A → A/B → A/B/C then collapsing A removes descendant keys.

### 5. Batch preview_panes N+1 on teardown — **done**
- Added `close_persisted_many/1`; single-pane close delegates to it.
- `expire_vanished_panes/2` and `session_terminated` batch the DB close, then `do_deregister(..., persist?: false)`.
- Test: multi-pane topology expire leaves all persisted rows `status: :closed`.
- `PreviewControl.close_session` / `Previews.close` still run per deregister; unique control sessions close once as ETS entries disappear (same as file_panes pattern).

### 6. Remove dead dependencies — **done** (all four confirmed unused in app code)
Grep before removal:
| Dep | App/code refs | Action |
|-----|---------------|--------|
| `xamal` | none (mix only) | removed |
| `ex_ast` | none direct (transitive of `reach`/`igniter`) | direct dep removed; remains in lock as transitive |
| `ex_dna` | none (mix only) | removed |
| `systemdkit` | none (hand-rolled systemd elsewhere) | removed |

Also unlocked unused transitives (`rebus`, `typedstruct`). `mix deps.unlock --unused` + `mix deps.get` + compile clean.

### 7. Remove stale boundary deps — **skipped**
Brief claimed `GitCtl` / `ExecCtl` / `McpCtl` do not exist. Grep shows they are **real modules** under `dev_ide_core/lib/` and are heavily used (`GitCtl.Inspector`, `ExecCtl.Allowlist`, `McpCtl.Tool`, etc.). Removing them from `lib/casein_domain.ex` would surface real cross-boundary needs incorrectly. **Left the deps list unchanged.**

### 8. Patch-level dependency bumps — **done** (with one skip)
| Package | Change | Notes |
|---------|--------|-------|
| `ecto` | 3.14.0 → 3.14.1 | patch |
| `plug` | 1.20.2 → 1.20.3 | patch |
| `postgrex` | 0.22.2 → 0.22.3 | patch |
| `ecto_sql` | 3.14.0 (unchanged) | already current |
| `exqlite` | **skipped** | only available bump was 0.37.0 → 0.38.0 (minor) |

### 9. Tests for security-sensitive modules — **done**
- `test/casein/previews/artifact_protection_test.exs` — `protect/2`, `protected/1`, `clear/0`, prune-gate behavior.
- `test/casein_web/plugs/deploy_webhook_auth_test.exs` — 503 unconfigured, 400 missing body / invalid JSON, 401 missing/invalid signature, valid path assigns payload.

### 10. Close OPTIONS forward-auth spoof — **done**
- `ForwardAuth.call/2` now matches `OPTIONS` first → **405 Method Not Allowed**, never reads `X-Auth-Request-Email`.
- Moduledoc updated: Caddy skips oauth2-proxy for OPTIONS; preview-proxy `match :*` would otherwise accept a spoofed header.
- **CORS preflight:** preview-proxy iframe content is same-origin; browsers do not need CORS preflight for those loads. OPTIONS was only method-forward completeness in tests — not a legitimate preflight requirement for embedded apps. Updated `preview_proxy_controller_test` to stop expecting OPTIONS 200 through the pipeline.
- Plug test: OPTIONS + spoofed email → 405, no identity; GET + header still works.

## Gate
- `mix format` applied.
- `bash scripts/pre-push-check.sh` **passed** (seed=1, 3993 tests, coverage 79.70%).
  Earlier attempts hit pre-existing flakes under concurrent load on this host
  (`WorkspaceLive` template library UI race; `SessionOwner` telemetry open-attachment
  baseline pollution). Both failures passed in isolation and are unrelated to this batch.

## Commits (one per numbered item + format)
1. `perf(notifications): batch mark_all_read into a single UPDATE`
2. `perf(notifications): index user_id + dedupe_key for recent_duplicate`
3. `perf(ets): enable read/write concurrency on shared public tables`
4. `perf(file-tree): drop descendant keys when collapsing a tree node`
5. `perf(preview_panes): batch close_persisted on multi-pane teardown`
6. `chore(deps): remove unused xamal, ex_ast, ex_dna, systemdkit`
7. *(skipped — no commit)*
8. `chore(deps): patch-bump ecto, plug, and postgrex`
9. `test: cover ArtifactProtection and DeployWebhookAuth plugs`
10. `security(forward_auth): reject OPTIONS so spoofed identity cannot proxy`
+ `style: mix format after audit fixes`
