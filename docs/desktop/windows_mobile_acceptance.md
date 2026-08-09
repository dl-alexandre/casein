# Windows mobile acceptance

**Direction of record:** GitHub issue [#371](https://github.com/dl-alexandre/casein/issues/371)
is the one authoritative acceptance checklist. This document defines its
reproducible evidence; focused issues hold external evidence without creating
competing completion lists.

## Evidence status

| Requirement | Repository evidence | Status |
|---|---|---|
| Deliberate Trusted LAN enable/disable | Tray toggle, UAC boundary, runtime restart, selected-address state | Implemented; Windows package CI required |
| Narrow firewall ownership | Private profile, selected local address and port, `LocalSubnet`, Casein-owned rule group, disable/uninstall cleanup | Implemented; elevated Windows smoke required |
| Deterministic address selection | Private RFC1918 address, physical interface, default route, metric, interface index, address ordering; VPN/Hyper-V/WSL/tunnels fail closed | Implemented; multi-adapter hardware smoke required |
| Stable origin across URL changes | Installation-scoped `windows-<uuid>` plus mobile profile reconciliation by origin id | Covered by automated tests |
| Credential isolation | Windows DPAPI and origin-qualified mobile profiles | Covered by automated tests |
| Resume/intervene safety | Shared authoritative-refresh, origin, locator, role, idempotency, and audit contracts | Covered by existing server/mobile tests |
| Packaging lifecycle | Signed offline archive; one-command per-user install/repair/uninstall; backup, rollback, autostart, support bundle | Windows CI smoke and clean-machine harness exist; clean Windows 11 evidence required |
| Production signing/update trust | Whole-payload hash manifest; production mode signs all PE/PowerShell executables, root manifest, and update catalog | Code complete; production-key evidence is #376 |
| Native Windows/macOS builds | Target-OS workflows exist | Runner availability and successful artifact evidence required |
| Physical iPad/Android matrix | Procedure below | External device evidence is #377 |
| Authenticated deployed cockpit | Procedure below | Operator evidence is #378 |

The original issue remains open until all rows are evidenced. A source test,
unsigned artifact, unauthenticated health response, simulator, or desktop
browser is not a substitute for the named external evidence.

## Trusted LAN contract

Trusted LAN is off by default. Enabling it from the notification-area menu:

1. asks for Windows administrator consent;
2. considers only `Up`, `Private` network profiles with RFC1918 IPv4 addresses;
3. excludes VPN, tunnel, Hyper-V, WSL, loopback, and common VM adapters;
4. selects deterministically by default-route presence, interface metric,
   interface index, then address;
5. creates one inbound firewall rule scoped to `Private`, the selected address,
   the packaged Erlang executable, current Casein port, TCP, and `LocalSubnet`;
6. restarts Casein with the LAN address added to its origin allowlist.

If no eligible interface exists, enable fails closed. Casein never silently
falls back to a VPN or virtual adapter. Disable returns the runtime to loopback
and removes every rule in the Casein-owned firewall group. Uninstall performs
the same elevated cleanup before removing the release.

The LAN URL is deliberately plain HTTP and address-based. No certificate or
hostname continuity is implied. When DHCP, Wi-Fi/Ethernet, or routing changes,
disable and re-enable Trusted LAN, then deliberately re-pair Device Link using
the new URL. The server returns the same installation origin id, so the mobile
client updates the existing Windows profile instead of creating a duplicate.
There is no silent failover.

## Windows release/signing procedure

Run from a clean native Windows checkout:

```powershell
scripts\package-windows-desktop.ps1 `
  -OutputPath dist\Casein-windows-x64 `
  -SigningCertificateThumbprint <production-code-signing-thumbprint> `
  -RequireSigned
scripts\test-windows-desktop-package.ps1 `
  -PackageRoot dist\Casein-windows-x64
```

Record the tagged revision, certificate subject/thumbprint (never the private
key), Windows runner image, archive SHA-256, update-catalog signature result,
and smoke logs. Verify a mutated payload and mutated update manifest are both
rejected. The complete clean-machine gate, including WSL-absent install,
autostart, update, rollback, repair, support bundle, and uninstall, is tracked
in #376.

For a production-signed extracted archive on a disposable Windows 11 test
account, run the repository-provided lifecycle gate under Windows PowerShell
5.1:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\windows\Test-CaseinCleanMachine.ps1 `
  -PackageRoot . `
  -AcceptDestructiveCleanMachineTest `
  -RequireNoDeveloperTooling `
  -EvidencePath "$env:USERPROFILE\Desktop\casein-windows-acceptance.json"
```

Repeat the lifecycle gate from deliberately prepared extracted package roots to
cover path handling. These switches fail closed unless the requested path shape
is actually active:

```powershell
# A local extraction root containing spaces and at least 180 characters.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\windows\Test-CaseinCleanMachine.ps1 `
  -PackageRoot . `
  -AcceptDestructiveCleanMachineTest `
  -RequireNoDeveloperTooling `
  -RequirePackageRootWithSpace `
  -RequireLongPackageRoot

# A protected test share; never put credentials in the UNC path.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\windows\Test-CaseinCleanMachine.ps1 `
  -PackageRoot . `
  -AcceptDestructiveCleanMachineTest `
  -RequireNoDeveloperTooling `
  -RequireUncPackageRoot
```

The destructive acknowledgement is mandatory because the harness installs,
damages one manifest-covered installed file, proves offline repair restores it,
verifies launch-at-sign-in targets the stable installed launcher and is removed
by uninstall, uninstalls, and removes Casein user data. It refuses unsigned packages,
pre-Windows 11 hosts, non-Windows-PowerShell 5.1 execution, installed WSL
distributions, or language/developer tools on `PATH`. The JSON evidence
(`schema` 3) records OS/package/certificate identity, safe path
kind/length/space prerequisites, per-phase timestamps plus outcomes, and explicit
`claims.real_reboot=false` / `claims.clean_machine_no_tooling` (the latter only
when `-RequireNoDeveloperTooling` was satisfied), but never the actual package
root, UNC server/share, tokens, URLs, database contents, or private-key material.
A repository, unsigned CI, or **Linux/devbox run on a host that already has
toolchains, certificates, and caches** is not clean-machine evidence and must
not be attached to #376 as such.

Restart and reboot persistence is a separate two-stage harness that survives a
real host reboot with an explicit continuation marker (no tokens, package
roots, or private paths):

```powershell
# Stage 1 — install, enable launch-at-sign-in, write continuation marker, stop.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\windows\Test-CaseinRebootPersistence.ps1 `
  -PackageRoot . `
  -AcceptDestructiveCleanMachineTest `
  -Stage prepare `
  -EvidencePath "$env:USERPROFILE\Desktop\casein-windows-reboot-acceptance.json"

# Reboot the disposable host, then stage 2 — prove boot stamp changed, install
# identity and stable autostart survived, then uninstall/cleanup.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\windows\Test-CaseinRebootPersistence.ps1 `
  -PackageRoot . `
  -AcceptDestructiveCleanMachineTest `
  -Stage continue `
  -EvidencePath "$env:USERPROFILE\Desktop\casein-windows-reboot-acceptance.json"
```

`-Stage auto` resumes when a valid `awaiting_reboot` marker is present and
otherwise prepares. The continue stage fails closed if the Windows boot stamp
is unchanged and only then sets `claims.real_reboot=true`. Package smoke runs
`-SelfTestContinuation` (marker round-trip only); that path never sets
`real_reboot` and is **not** reboot or clean-machine evidence. Attach only
redacted real-host JSON with `claims.real_reboot=true` to #376.

The Windows package smoke also writes malformed desktop settings and runtime
marker files into its disposable LocalAppData root. It verifies that the tray
library falls back to an automatically selected port with launch-at-sign-in
disabled, then removes the invalid PID and runtime-status markers without
reporting the runtime as ready. The same smoke proves the stable launcher fails
closed on malformed `current.json`, does not disclose the disposable local data
root through acceptance evidence, and a verified package atomically restores
valid installed-release state. It also proves an offline reinstall removes a
release-specific staging directory left by a dead installer PID while preserving
one owned by a live process. Capturing these recoveries on a production-signed
disposable host remains external evidence.

The current repository-gap subtraction and sequencing record is
[`windows_acceptance_gap_audit.md`](windows_acceptance_gap_audit.md). Keep that
audit subordinate to #371/#376 and update it when a listed slice lands.

The installed tray exposes **Check for updates** only as thin release
infrastructure. The updater reads the channel URL embedded in
`casein.relmeta.json`, requires credential-free HTTPS, verifies the adjacent
signed file catalog against the manifest, requires the catalog signer to match
the signer pinned by the installed release, and refuses channel or
profile/target/repository-adapter changes. It then verifies archive size and
SHA-256 before presenting an explicit install confirmation. After installation
it waits for loopback health; failure stops the new tray/runtime, restores the
encrypted pre-update database snapshot and previous release, and relaunches
that release.

For protected-runner evidence, publish the archive and channel manifest
together, with the signed catalog at `<manifest-url>.cat`. Exercise current,
available, wrong-channel, wrong-signer, mutated-manifest, mutated-archive, and
post-install health-failure cases. Redact URLs if they contain infrastructure
details; never use URLs containing credentials.

## Physical device matrix

Run every row once on a physical iPad and once on a physical Android device.
Record OS/app/server versions, active interface, timestamps, and redacted
screenshots or logs.

| State | Required observation |
|---|---|
| Initial pair | Device Link reports the Windows origin id and distinct display name |
| Warm | Live cards refresh and one bounded follow-up reaches only the revalidated agent pane |
| Background | Foreground reconnects to the explicitly active origin |
| Killed | Cold start shows cached cards read-only until authoritative refresh |
| Host restart | Same origin/profile reconnects without credential crossover |
| Device restart | Same origin/profile remains selected only when explicitly active |
| Offline/firewall denied | Understandable unavailable state; no retarget or silent failover |
| VPN/interface change | No virtual adapter exposure; deliberate re-enable/re-pair updates the same origin |
| Tampered locator/origin | Connect/mutate fails closed |
| Operator/verify target | Follow-up fails closed |
| Escalation | Exact authenticated link opens the existing web/PWA cockpit |

Attach evidence to #377. Never attach QR payloads, bearer tokens, or reusable
credentials.

## Post-deploy verification

After the PR is present on `origin/master`, wait for the on-box poller to deploy
that exact SHA. Verify the timer/service result and revision, then authenticate
to the production cockpit and inspect Agents, terminal topology, and a
read-only MCP/preview path. Capture redacted evidence and confirm no manual
deployment drift. Do not hand-edit the live release. Attach the result to #378.
