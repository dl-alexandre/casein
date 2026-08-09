# PR gate Postgres DSM / `/dev/shm` (self-hosted)

**Status:** Active ops note  
**Tracks:** need-ci-shm-53100 / casein#744  
**Last updated:** 2026-08-09

Intermittent full-suite failures on the self-hosted PR gate look like disk full:

```text
ERROR 53100 (disk_full): could not resize shared memory segment "/PostgreSQL.<n>"
  to 33554432 bytes: No space left on device
```

That string is **misleading**. On this devbox it is Postgres **dynamic shared
memory (DSM)** under `/dev/shm`, not root disk exhaustion and not the product
`42P10` attention-index bug (fixed in #749).

## What already landed

| Change | Where | Effect |
|--------|-------|--------|
| Single-flight PR gate | `.github/workflows/pr-gate.yml` concurrency group `pr-gate-devbox-self-hosted`, `cancel-in-progress: false` (#753) | At most one full `gate` job on the shared runner host. Other PRs **queue**; they do not cancel an in-flight run. |
| ExUnit case cap | `test/test_helper.exs` `max_cases: 4` | Keeps one suite from opening schedulers-worth of sandbox connections / child pressure. |
| Repo pool cap | `config/test.exs` `pool_size: min(schedulers*2, 10)` | Avoids `53300 too many clients` against the shared host Postgres. |
| Per-run tmux label | `test/test_helper.exs` `casein_test_<pid>` | Concurrent suites (when they still happen outside the PR gate) do not `kill-server` each other. |

Single-flight removes the dominant multi-gate multiplier. Residual 53100 risk
remains when **one** full suite still exhausts the kernel **segment count**
while `/dev/shm` byte capacity stays nearly empty.

## Re-verify before changing the box

```bash
df -h /dev/shm
sysctl kernel.shmmni kernel.shmmax kernel.shmall
ls /dev/shm/PostgreSQL.* 2>/dev/null | wc -l
pgrep -c postgres
pgrep -af 'mix test|pre-push-check' | head
ipcs -u   # "segments allocated" under Shared Memory Status
```

Reference snapshot (2026-08-09, runner host):

| Signal | Value |
|--------|-------|
| `/dev/shm` | 62G total, ~23M used, **~62G free** |
| `kernel.shmmni` | **4096** (only limit near binding) |
| `kernel.shmmax` / `shmall` | ~unlimited |
| `PostgreSQL.*` files | a few MB, often stale; **do not delete** while backends live |
| Concurrent full suites when 53100 hit | can be **1** — multi-gate is real but not sufficient alone |

A ~33MB DSM resize failing against tens of GB free is a **segment-count**
problem (`shmmni`), not a byte-capacity problem. Postgres backends allocate many
small DSM segments during parallel query / sandbox work; the kernel reports
segment exhaustion as `ENOSPC` / "No space left on device".

**Do not** `rm /dev/shm/PostgreSQL.*` as a fix. It reclaims almost nothing and
can disturb live backends.

---

## Follow-up 1 (preferred next ops step): raise `kernel.shmmni`

Directly targets the limit the numbers implicate. One reversible sysctl on the
**shared** multi-tenant box — needs a human host ACK before apply.

### Procedure (attended)

1. Record baseline:

   ```bash
   date -u
   sysctl kernel.shmmni
   ipcs -u
   df -h /dev/shm
   ```

2. Raise for the running kernel (immediate, non-persistent):

   ```bash
   # example: 4096 -> 32768
   sudo sysctl -w kernel.shmmni=32768
   ```

3. Confirm:

   ```bash
   sysctl kernel.shmmni   # expect 32768
   ```

4. Persist across reboot **only after** a green gate under the new value:

   ```bash
   # idempotent drop-in — adjust path to house style if the box already has one
   echo 'kernel.shmmni = 32768' | sudo tee /etc/sysctl.d/99-casein-shmmni.conf
   sudo sysctl --system
   ```

5. Roll back if anything regresses:

   ```bash
   sudo sysctl -w kernel.shmmni=4096
   sudo rm -f /etc/sysctl.d/99-casein-shmmni.conf
   sudo sysctl --system
   ```

### Why 32768

4× the historical default. Still tiny in absolute terms relative to 62G shm.
If 53100 persists after single-flight **and** this raise, escalate to follow-up 2
rather than chasing ever-larger `shmmni` alone.

### Coordination

- Apply only when **no** full `pre-push-check` / PR `gate` is mid-suite (check
  `pgrep -af 'mix test|pre-push-check'` and the Actions run list).
- Do not combine with unrelated kernel/sysctl experiments on the same change
  window.

---

## Follow-up 2 (design only): dedicated gate Postgres with `shm_size: 1g`

Use if single-flight + `shmmni` still leave 53100. **Design proposal — not
implemented.** Product `docker-compose.yml` Postgres stays the portable smoke
stack and is intentionally separate from the CI host database the suite hits
today (`localhost` / default `postgres` role in `config/test.exs`).

### Goals

- Isolate gate DSM from host Postgres backends that serve prod (`15432`), other
  agent suites, and long-lived services.
- Give the gate container an explicit Docker shm budget (`shm_size: '1gb'`) so
  DSM resize is not fighting the host `tmpfs` + `shmmni` mix alone.
- Keep prod data path untouched: gate DB is throwaway, created/migrated per job
  or wiped between runs.

### Sketch (not committed)

```yaml
# docs sketch only — e.g. docker-compose.pr-gate.yml (future)
services:
  gate-postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: casein_test
    # Docker's default /dev/shm is 64MB — far too small for DSM-heavy suites.
    shm_size: "1gb"
    ports:
      - "127.0.0.1:55433:5432"   # host loopback only; avoid 5432/15432
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d casein_test"]
      interval: 2s
      timeout: 3s
      retries: 20
    tmpfs:
      - /var/lib/postgresql/data:size=2g   # optional: no durable gate data
```

Gate job wiring (conceptual):

1. Start compose file before `pre-push-check.sh`.
2. Point the suite at it without rewriting prod config, e.g.:

   ```bash
   export PGHOST=127.0.0.1
   export PGPORT=55433
   export PGUSER=postgres
   export PGPASSWORD=postgres
   # and/or CASEIN-specific overrides if introduced later
   mise exec -- mix ecto.create ecto.migrate   # test env
   bash scripts/pre-push-check.sh
   ```

3. Tear down the container at job end (`docker compose down -v`) so DSM and
   connections cannot leak into the next queued PR.

### Non-goals

- Do not put `shm_size` on the **product** compose Postgres as a silent side
  effect of this design; that stack is for portable smoke, not the devbox gate.
- Do not point the gate at prod `15432` / `casein_prod`.
- Do not run a second full suite on the host "to test the design" while a live
  gate is in flight.

### Cost / complexity

Higher than follow-up 1: runner image needs Docker permission, port allocation,
migrate/create each run, and clear ownership of who starts/stops the container
if the job is cancelled mid-queue. Prefer `shmmni` first.

---

## Operator checklist when 53100 reappears

1. Confirm it is DSM (`/PostgreSQL.` in the message), not root `df -h /`.
2. Check whether single-flight queued or whether a **local** agent
   `pre-push-check` overlapped the Actions gate (`pgrep -af mix test`).
3. Capture `sysctl kernel.shmmni`, `df -h /dev/shm`, `ipcs -u`, postgres count.
4. Prefer: finish/queue other suites → re-run **one** gate. Avoid thrash.
5. If still red after a clean single run: apply follow-up 1 (host ACK) before
   investing in follow-up 2.

---

## Optional automation notes (not wired)

A future gate preflight could refuse or warn before `mix test` when DSM segment
headroom is thin. **Do not implement from this doc alone** — single-flight (#753)
plus attended `shmmni` is the preferred path; automation is only useful if a
single suite still hits 53100 after those.

### What it would measure

| Input | Source |
|-------|--------|
| Limit | `kernel.shmmni` via `sysctl -n kernel.shmmni` |
| In use | `ipcs -u` → "segments allocated", or `ls /dev/shm/PostgreSQL.* \| wc -l` as a weaker Postgres-only proxy |
| Concurrent suites | `pgrep -c -f 'mix test|pre-push-check'` (local overlap is still a failure mode under single-flight Actions) |

### Sketch output (print-only)

```text
ci-shm preflight: shmmni=4096 segments_allocated=312 postgres_dsm_files=3
  mix_test_procs=0 headroom=3784 (92% free) — ok
```

or, when headroom is low (example thresholds only — not policy):

```text
ci-shm preflight: shmmni=4096 segments_allocated=3900 postgres_dsm_files=180
  mix_test_procs=1 headroom=196 (4% free) — WARN: DSM segment headroom thin;
  prefer queue/wait over starting another full suite (see docs/ops-pr-gate-postgres-shm.md)
```

### Placement if ever added

- Early in `scripts/pre-push-check.sh` (warn) or a dedicated
  `scripts/ci-shm-preflight.sh` called from the PR gate step.
- Exit non-zero only with an explicit opt-in env (e.g. `CASEIN_CI_SHM_STRICT=1`);
  default should be advisory so a noisy `ipcs` parse never bricks deploys.
- Never delete `/dev/shm/PostgreSQL.*` from automation.

## Related

- `.github/workflows/pr-gate.yml` — required `gate` job, single-flight group
- `scripts/pre-push-check.sh` — suite the gate runs
- `scripts/ensure-ci-runner.sh` — self-hosted runner install
- `docs/subsystems/release_smoke.md` — release phase after the suite
- `test/test_helper.exs` — `max_cases: 4`, per-run tmux label
- casein#744 / need-ci-shm-53100 — fleet reliability parent
