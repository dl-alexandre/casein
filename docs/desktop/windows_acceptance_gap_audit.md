# Native Windows acceptance gap audit

**Snapshot:** 2026-08-10 after Windows SQLite open-clarification H28 portability
slice (mobile inbox on desktop host path) on top of #794/#795 acceptance harnesses
+ #377 physical-lab definition
**Authority:** issue #371 remains the parent checklist; #376 holds production
signing and clean-machine evidence; #377 holds physical iPad/Android matrix
evidence. This audit subtracts repository work that is already merged or actively
owned. It does not replace those issues.

## Subtracted work

| PR | Evidence removed from the open repository gap |
|---|---|
| #468 | SQLite integrity-before-migration and DPAPI-encrypted, validated update backups/rollback data restore |
| #469 | ConPTY descendant containment with a kill-on-close Job Object |
| #470, #472 | Packaged native Playwright/Chromium preview runtime, native process adapter, and closed preview workstream |
| #477 | Signed-channel validation, pinned signer/channel/target, archive verification, and health-triggered rollback |
| #478 | Native session/window/pane topology, capture, resize, roles, and strict target validation |
| #486 | Signed offline install/repair/uninstall entry points and destructive clean-machine evidence harness |
| #498 | DPAPI-only local token rotation with health validation, exact rollback, and redacted diagnostics |
| #500 | Deterministic Windows package runtime preparation and bounded release-file integrity manifest |
| #502 | Token-free provider executable/version/authentication preflight diagnostics |
| #504 | Bounded crash/recovery state, automatic runtime recovery evidence, and sanitized support inclusion |
| #505 | Windows-safe native Git worktree creation and argv-only Git execution |
| #516 | Launch-at-sign-in targets the stable installed launcher and uninstall removes it |
| #614 | Signed Windows development bootstrap channel (production Authenticode remains separate) |
| #794 | Two-stage reboot-resumable acceptance runner (`Test-CaseinRebootPersistence.ps1`) with boot-stamp fail-closed continue; clean-machine schema-3 phase timestamps/outcomes and path prerequisites |
| #795 | Explicit `claims.real_reboot` / `claims.clean_machine_no_tooling` on both harnesses; reboot marker `-SelfTestContinuation` in package smoke; docs prove/cannot-prove matrix (no parallel two-stage in CleanMachine) |
| #377 lab def | Operator runbook [`windows_physical_device_lab.md`](windows_physical_device_lab.md), fixed evidence schema, and `scripts/verify_windows_physical_device_lab.sh` (`--self-check` never sets `physical_*=true`; `--validate-evidence` rejects secrets and dishonest `matrix_passed`) |
| SQLite H28 | Desktop `CASEIN_REPO_ADAPTER=sqlite` open-clarification hydration shares `OpenClarifications.project/4` (filter resolved **before** newest-per-pane distinct) with MemoryAdapter; Postgres Ecto keeps SQL `NOT EXISTS` + `DISTINCT ON`. Prevents silent unanswerable mobile inbox on Windows host path |

## Remaining repository-feasible gaps

| Gap | Current evidence | Next bounded slice |
|---|---|---|
| Path spaces, long paths, and UNC extraction | Clean-machine harness can fail closed unless the requested path shape is active and records only safe kind/length/space facts | Execute production-signed canaries on disposable local and protected-share roots; attach redacted JSON to #376 |
| Corrupted state recovery | Release-file repair, SQLite pre-migration corruption rejection, malformed settings/runtime cleanup, verified-package recovery for malformed `current.json`, and interrupted installer staging cleanup are package-smoked; staging owned by a live process is preserved | Capture these recoveries on a production-signed disposable host |
| Update rollback evidence | Implementation and source/package smokes exist | Capture redacted before/after release identity, health-failure outcome, and restored database digest on a signed channel |
| No-tooling install/repair/uninstall | Harness rejects language tools and installed WSL distributions when asked | Run it on a production-signed disposable Windows 11 account **without** toolchains and attach its JSON to #376 |
| Restart/reboot host evidence | Repository runner exists (`windows/Test-CaseinRebootPersistence.ps1`); continue fails closed if boot stamp unchanged; package smoke only runs marker self-test | Run prepare → **real reboot** → continue on a disposable signed host and attach JSON with `claims.real_reboot=true` to #376 |

## What repository / this-box runs prove vs cannot prove

| Claim | Proven by repo / package CI / this devbox? | Requires external host? |
|---|---|---|
| Continuation marker write/read/reject-malformed | Yes (`-SelfTestContinuation` in package smoke) | No |
| Continue refuses unchanged boot stamp (code path) | Yes (source contract + fail-closed string) | Real reboot still external |
| Per-phase timestamps + explicit claims fields | Yes | No |
| Production Authenticode on PE/scripts/catalog | Code path exists (`-RequireSigned`) | Yes — production cert on protected Windows runner |
| Real reboot launch-at-sign-in persistence | Harness stages it; `claims.real_reboot` flips only after boot stamp changes | Yes — disposable Win11 + actual reboot |
| Clean machine without developer tooling/WSL | Harness can refuse tools when asked | Yes — host without mix/node/git/WSL; **this Linux/devbox never qualifies** |
| Physical lab procedure + evidence validator | Yes (`windows_physical_device_lab.md` + verify script) | Real devices still external |
| GitHub Actions desktop artifact upload | Workflow build/smoke may pass | **Blocked account-wide** by Actions artifact storage quota (upload-only red). Pruning this repo cannot clear the quota. |

## External acceptance blockers

The following cannot be converted into repository evidence: production
Authenticode/private-key execution, a disposable clean Windows 11 host with no
developer tooling or WSL distribution, a real reboot between prepare and
continue, **completed** physical iPad/Android matrix rows on real hardware
(#377 — lab definition can land without devices; `matrix_passed` cannot),
authenticated production cockpit verification (#378), companion signing/install
prerequisites (#416), and durable GitHub Actions artifact retention while the
account storage quota is exhausted. A green source test, unsigned package,
`-SelfTestContinuation` run, `lab_unreachable_on_this_host` self-check,
simulator, OAuth redirect, zero-step workflow, or Linux/devbox host with
toolchains/certs/caches is not a substitute.
