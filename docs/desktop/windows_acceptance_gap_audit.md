# Native Windows acceptance gap audit

**Snapshot:** 2026-08-02 after PRs #509, #516, #521, and #531
**Authority:** issue #371 remains the parent checklist; #376 holds production
signing and clean-machine evidence. This audit subtracts repository work that is
already merged or actively owned. It does not replace either issue.

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

Active work is also excluded: #509 owns support-bundle allowlisting and #513
owns native provider worktree launch plans. Their files and interfaces are not
available to this track until those PRs land or explicitly coordinate a change.

## Remaining repository-feasible gaps

| Gap | Current evidence | Next bounded slice |
|---|---|---|
| Launch at sign-in across update/rollback/uninstall | Shortcut was release-pinned and uninstall left it behind | Point it at the stable installed launcher; package and clean-machine smokes verify creation, target, and cleanup |
| Restart/reboot persistence | Runtime crash recovery is covered; real sign-out/reboot is not automated | Add a two-stage, reboot-resumable acceptance runner with an explicit continuation marker and bounded evidence |
| Path spaces, long paths, and UNC extraction | Clean-machine harness can fail closed unless the requested path shape is active and records only safe kind/length/space facts | Execute production-signed canaries on disposable local and protected-share roots; attach redacted JSON to #376 |
| Corrupted state recovery | Release-file repair, SQLite pre-migration corruption rejection, malformed settings/runtime cleanup, verified-package recovery for malformed `current.json`, and interrupted installer staging cleanup are package-smoked; staging owned by a live process is preserved | Capture these recoveries on a production-signed disposable host |
| Update rollback evidence | Implementation and source/package smokes exist | Capture redacted before/after release identity, health-failure outcome, and restored database digest on a signed channel |
| No-tooling install/repair/uninstall | Harness rejects language tools and installed WSL distributions | Run it on a production-signed disposable Windows 11 account and attach its JSON to #376 |
| Operator evidence precision | One JSON lifecycle record exists; support diagnostics are actively hardened in #509 | Add phase timestamps/outcomes and explicit prerequisite/path facts while keeping tokens, URLs, database contents, and private-key material absent |

## External acceptance blockers

The following cannot be converted into repository evidence: production
Authenticode/private-key execution, a disposable clean Windows 11 host with no
developer tooling or WSL distribution, physical iPad/Android coverage (#377),
and authenticated production cockpit verification (#378). A green source test,
unsigned package, simulator, OAuth redirect, or zero-step workflow is not a
substitute.
