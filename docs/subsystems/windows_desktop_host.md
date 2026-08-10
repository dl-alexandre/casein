# Windows desktop host

> Thin Windows infrastructure that supervises the packaged Casein release and
> opens the existing Phoenix/LiveView cockpit. It is not a second product UI.

## Mobile open-clarification inbox (SQLite)

Windows desktop releases compile with `CASEIN_REPO_ADAPTER=sqlite`. Mobile Needs
Me / open-clarification hydration must filter resolved requests **before**
newest-per-pane distinct (H28). Doing distinct first permanently hides older
still-open requests when a newer same-pane request was resolved — unanswerable
with no marker.

The portable projector is `Casein.Agents.AgentEvents.OpenClarifications`. The
SQLite Ecto adapter and MemoryAdapter both call it; the Postgres Ecto path keeps
SQL `NOT EXISTS` + `DISTINCT ON` with the same filter-before-distinct order.
Repository evidence:

```bash
mise exec -- mix test \
  test/casein/agents/agent_events/open_clarifications_test.exs \
  test/casein/agents/agent_events_ecto_adapter_test.exs
```

This does not claim physical Device Link or clean Windows 11 evidence (#376/#377).

## Crash and recovery diagnostics

The tray owns the release process through a kill-on-close Job Object and checks
the loopback `/healthz` endpoint. When an owned runtime PID is no longer alive,
it writes `%LOCALAPPDATA%\Casein\crash-state.json`, retries startup at most three
times, and updates that single latest-incident record with the recovery result.

The schema is intentionally bounded to timestamps, numeric runtime PID and exit
code, retry count, and one of `detected`, `recovering`, `recovered`, `exhausted`,
or `startup_failed`. Never add command lines, environment values, exception
messages, tokens, paths, or user data to this file.

Operators can use the tray's **Open logs** and **Create support bundle** actions.
The bundle reconstructs crash state from the allowlist rather than copying the
source JSON, excludes credentials and SQLite data, and substitutes an invalid
state marker when validation fails. Repository evidence is provided by:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\test-windows-crash-diagnostics.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\test-windows-support-bundle.ps1
```

Every JSON file in the bundle is reconstructed from a fixed diagnostic schema.
Desktop settings retain only port and launch-at-sign-in state; runtime state is
type-checked against the loopback status contract; Trusted LAN state omits the
runtime executable path and reconstructs its URL; installed-release state omits
release and backup paths while retaining version, revision, signer identity,
timestamp, and rollback-availability booleans. Unknown fields never enter the
archive, and invalid state is represented by a fixed non-sensitive marker.

This smoke requires Windows PowerShell 5.1. It does not replace production
Authenticode, protected-runner, or clean Windows 11 crash/recovery evidence.

## Clean-machine and reboot-persistence acceptance

Packaged offline archives include two destructive acceptance harnesses under
`windows/`. Both require Windows 11, Windows PowerShell 5.1, a valid production
Authenticode release manifest, and
`-AcceptDestructiveCleanMachineTest` on a disposable account:

| Harness | Purpose |
|---|---|
| `Test-CaseinCleanMachine.ps1` | One-shot install → launch-at-sign-in → repair → uninstall. Evidence `schema` 3 records phase timestamps/outcomes and path prerequisites only. |
| `Test-CaseinRebootPersistence.ps1` | Two-stage prepare → reboot → continue. Writes a bounded continuation marker under `%LOCALAPPDATA%\Casein\acceptance\` (boot stamp, release revision, origin id prefix). Continue fails closed when the boot stamp is unchanged. |

Neither evidence file may contain package roots, UNC server/share paths, tokens,
URLs, database contents, or private-key material. Attach real-host JSON to
issue #376; repository smokes and unsigned CI are not substitutes. Procedures
live in [`docs/desktop/windows_mobile_acceptance.md`](../desktop/windows_mobile_acceptance.md).
