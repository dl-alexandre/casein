# Supply-chain hygiene

**Status:** Active

**Owner:** Release engineering

**Last updated:** 2026-08-13

## Hex

`mix deps.audit` and `mix hex.audit` run in `mix precommit` / `mix precommit.ci`.
The hex advisory surface is the existing gate; do not add a second scanner
here without an issue.

## npm (`assets/` and `priv/scripts/`)

Both trees sit outside hex tooling. Install calls keep `--no-audit` for
speed/determinism. The scan is `scripts/npm-audit.sh`
(`npm audit --package-lock-only --audit-level=high` on both lockfiles).

Every product-tree install site must invoke that script or an equivalent
`npm audit --… --audit-level=high`. `scripts/check-npm-audit-guard.sh`
fails the gate if a new `npm ci` / `npm install` skips the scan. Never
lower the level below `high` without an explicit issue.

## Oban (#931)

Oban stays declared. Tables were recreated
(`priv/repo/migrations/20260621140000_recreate_oban_tables.exs`) and
`Casein.Signals.ObanWorker` exists for the first real jobs: retention
sweeps for `runtime_lifecycle_events` and `notifications`, and moving
`AttentionInbox.prune_history/1` off the insert path.

Do **not** start an empty poller — that was ripped out in `6813e690`.
The first `use Oban.Worker` under `lib/` must also add Oban to
`Casein.Application` children. `test/casein/oban_fate_test.exs`
enforces that pairing.
