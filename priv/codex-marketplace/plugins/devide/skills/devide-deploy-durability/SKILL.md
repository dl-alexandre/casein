---
name: casein-deploy-durability
description: Make Casein changes durable through source control and the release gate. Use before deploying, after a manual dogfood deploy, when a drift banner appears, or whenever work must survive the next origin/master poller release.
---

# Casein deploy durability

1. Work in a linked agent worktree; treat the primary checkout as deploy infrastructure.
2. Check `docs/in-progress.md` and current `origin/master` before touching an active subsystem.
3. Run targeted tests while iterating, then run `mise exec -- mix precommit`.
4. Before a push to `master`, run `bash scripts/pre-push-check.sh`.
5. Commit only intended paths, fetch `origin/master`, and rebase before landing.
6. Push the branch or approved `master` update. The on-box poller deploys committed `origin/master` from a clean detached worktree.
7. Treat `bash scripts/deploy-local.sh` as temporary dogfooding only; it is not durable until the same change lands in Git.
8. Finish with `terminal_report_worktree` using the correct exit outcome.

Never edit `/opt/casein/release` by hand or describe an unpushed manual release as durable.
