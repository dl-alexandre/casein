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
```

This smoke requires Windows PowerShell 5.1. It does not replace production
Authenticode, protected-runner, or clean Windows 11 crash/recovery evidence.
