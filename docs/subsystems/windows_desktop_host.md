# Windows desktop host

> Thin Windows infrastructure that supervises the packaged Casein release and
> opens the existing Phoenix/LiveView cockpit. It is not a second product UI.

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
