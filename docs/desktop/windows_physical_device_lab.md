# Windows-origin physical device acceptance lab (#377)

**Authority:** parent checklist [#371](https://github.com/dl-alexandre/casein/issues/371);
this lab is the sole completion path for the physical iPad/Android matrix row.
Sibling evidence tracks (do not redefine their gates here):

| Issue | What it owns | Status signal |
|---|---|---|
| [#376](https://github.com/dl-alexandre/casein/issues/376) | Production Authenticode + clean Windows 11 machine | Harness honesty merged (#795); real signed host still external |
| [#382](https://github.com/dl-alexandre/casein/issues/382) | macOS desktop release evidence | Separate release channel |
| [#416](https://github.com/dl-alexandre/casein/issues/416) | Companion signing, install, physical distribution prerequisites | External Apple/Play/device storage blockers |
| [#371](https://github.com/dl-alexandre/casein/issues/371) / #794 | Windows pairing/resume product parity | Merged product + reboot harness; physical matrix still open |

The matrix procedure summary also lives in
[`windows_mobile_acceptance.md`](windows_mobile_acceptance.md). **This document
is the operator runbook and evidence contract.** A green source suite, emulator,
simulator, desktop browser, Bluetooth audio presence, or Linux/devbox probe is
**not** matrix completion.

## What this box can and cannot prove

| Claim | Proven on Linux/devbox / CI? | Requires |
|---|---|---|
| Lab procedure + fixed evidence schema exist | Yes (this doc + `scripts/verify_windows_physical_device_lab.sh`) | — |
| Evidence JSON rejects secrets and incomplete claims | Yes (validator + unit tests) | — |
| Host has `adb` / CoreDevice tooling installed | Maybe (self-check only) | Host packages |
| A physical Android is attached and exact package installed | **No** unless operator attaches one | USB/debug device + signed APK |
| A physical iPad is attached with exact signed build | **No** unless operator attaches one | Mac + profile (#416) + device |
| Windows origin host with Trusted LAN on private LAN | **No** from this Linux box alone | Windows workstation (#376 signed install preferred) |
| Firewall-denied / VPN / interface-change rows | **No** | Real network path on that LAN |
| Warm / background / killed / host+device restart rows | **No** | Real app process lifecycle on device |
| Operator/verify fail-closed + PWA escalation | **No** as physical proof | Device UI + Windows agent_pair topology |

**Honest outcome for unattended runners on this devbox:** run
`bash scripts/verify_windows_physical_device_lab.sh --self-check` and attach the
JSON. Expect `verdict: lab_unreachable_on_this_host` with
`claims.physical_android=false`, `claims.physical_ipad=false`, and
`claims.windows_origin_exercised=false`. That is a **successful lab definition
check**, not matrix pass. Do not close #377 on self-check alone.

## Prerequisites (operator, before any matrix row)

1. **Exact product revision** recorded as full git SHA (tagged release preferred).
   Companion install must match that SHA’s mobile build, not an older dogfood APK.
2. **Windows origin host** on a private LAN:
   - Trusted LAN deliberately enabled (UAC, private RFC1918, non-VPN adapter).
   - Installation-stable `origin_id` (`windows-<uuid>`) and distinct display name
     (`… (Windows)`).
   - `agent_pair` (or Windows native equivalent) with role-marked **agent**,
     **operator**, and **verify** targets available for fail-closed rows.
3. **Physical Android** (one device): USB debugging or equivalent log access;
   package `com.example.casein_mob` (see `native/casein_mob/android`); free
   storage sufficient for data-preserving install (#416).
4. **Physical iPad** (one device): signed `com.alexandrefamilyfarm.casein-mob`
   with a profile that includes the device (#416). Simulator is forbidden.
5. **Network scenarios prepared:** one path to deny the Windows LAN port
   (host firewall off/rule removed or client offline), and one Wi-Fi↔Ethernet or
   VPN/interface change that forces a new reachability URL.
6. **Clock sync** on Windows host and both devices (timestamps in evidence).

Do not start the matrix while #416 install/signing blockers still prevent the
exact-head binary from landing on-device. Record those under #416, not as #377
product failure.

## Forbidden evidence (automatic reject)

The validator fails closed if evidence contains any of:

- Pairing tokens, QR payloads, compact-pairing bodies, bearer/JWT-shaped strings
- Raw `origin_id` full UUID (prefix only: first 12 hex chars after `windows-`)
- Device UDID/serial reflected in free text (use opaque `device_label` only)
- Screenshots that show QR codes or credential fields
- `claims.physical_*=true` without every required row `outcome` in
  `{passed, failed}` for that platform (not `skipped` / `not_run`)
- `verdict: matrix_passed` unless both platforms are complete and
  `claims.windows_origin_exercised=true`

## Matrix rows (run once per physical platform)

Execute the table in order on **Android**, then again on **iPad**. Each row gets
one evidence object under `platforms.<android|ipad>.rows.<id>`.

| id | Operator action | Pass criteria | Evidence to record |
|---|---|---|---|
| `initial_pair` | Device Link pair to the **stable Windows origin** (not Devbox/Mac) | UI shows Windows display name; profile stores same installation origin; no second Windows profile created | Redacted screenshot; `origin_id_prefix`; wall time UTC |
| `warm_resume_followup` | App stays warm; open live Resume Card; send one bounded follow-up | Follow-up lands only on revalidated **agent** pane; operator/verify unchanged | Server audit id or pane hash delta note (no token); timestamp |
| `background_foreground` | Background app ≥30s; foreground | Reconnects to **explicitly active** Windows origin; no silent failover to Devbox/Mac | Timestamp; active origin label |
| `killed_cold_cached` | Force-stop / swipe away; cold start | Cached cards visible **read-only** until authoritative refresh; no mutation controls armed on stale cache | Screenshot of read-only affordance; timestamp |
| `host_restart` | Restart Casein tray/runtime on Windows (not full PC reboot unless convenient) | Same origin/profile reconnects; credentials do not cross to another origin | Timestamp; origin_id_prefix unchanged |
| `device_restart` | Reboot the phone/tablet | Same origin remains only if still explicitly active; no credential crossover | Timestamp |
| `offline_firewall_denied` | Deny path (Trusted LAN off, firewall rule removed, or client offline) | Understandable unavailable/denied state; no retarget; no mutate | Screenshot/log category only; timestamp |
| `vpn_interface_change_repair` | Change Wi-Fi/Ethernet or enable VPN so URL/IP changes; disable+enable Trusted LAN; deliberate re-pair/update | **Same** Windows profile updated; **no** duplicate Windows origin profile | Profile count before/after (integer); origin_id_prefix |
| `tampered_target_fail_closed` | Attempt connect/mutate with unknown or tampered origin/locator | Fails closed; no session mutate | Outcome + timestamp (no payload) |
| `operator_verify_fail_closed` | Aim follow-up at operator or verify target | Rejected; agent pane unchanged | Outcome + timestamp |
| `pwa_escalation` | Open exact authenticated escalation to web/PWA cockpit | Lands on expected auth boundary for that host (sign-in or cockpit); URL has no embedded bearer | Redacted screenshot of host chrome only |

### Shared Windows host checks (once per lab run)

Record under `windows_host` (not per-platform):

- OS build, Casein package/revision, Trusted LAN selected address **kind** only
  (`private_rfc1918` / `none`) — never the IP string if avoidable; if required for
  debug, redact to `/16` prefix.
- Confirmation that Devbox and Local Mac profiles remain distinct on each device
  after Windows pairing (`profiles_collision_free: true|false`).

## Operator procedure (repeatable)

```bash
# 0) On the lab operator machine (not necessarily the devbox): start evidence.
export LAB_SHA="$(git rev-parse HEAD)"   # exact companion/host revision under test
export EVIDENCE="$HOME/Desktop/casein-377-physical-lab-${LAB_SHA:0:12}.json"

# 1) Optional: prove this host cannot fake the matrix (devbox / CI).
bash scripts/verify_windows_physical_device_lab.sh --self-check \
  --evidence /tmp/casein-377-self-check.json
# Expect verdict lab_unreachable_on_this_host on a device-less Linux box.

# 2) After the human matrix, validate the filled evidence file:
bash scripts/verify_windows_physical_device_lab.sh \
  --validate-evidence "$EVIDENCE"
# Exit 0 only for verdict matrix_passed | matrix_failed | lab_incomplete
# with schema-valid claims. matrix_passed is the only close-#377 signal.
```

### Suggested Android identity capture (no secrets)

```bash
adb devices -l                    # ensure exactly the intended serial is present
adb shell getprop ro.product.model
adb shell getprop ro.build.version.release
adb shell dumpsys package com.example.casein_mob | sed -n '1,40p'
# Record model + release + versionName/versionCode only — never paste bugreport wholes.
```

### Suggested iPad identity capture (no UDID in evidence)

In Xcode → Devices and Simulators: record device marketing name + iPadOS version
+ app build number. Put a human `device_label` such as `coding-ipad` in evidence.
Do **not** copy UDID into the JSON or issue comments.

### Windows host

Prefer a production-signed package from the #376 procedure. Development unsigned
smoke may be used only if `windows_host.package_signed` is explicitly `false`
and the lab verdict will not be treated as release acceptance.

## Evidence JSON (schema 1)

Canonical schema:
[`scripts/schemas/windows_physical_device_lab_evidence.schema.json`](../../scripts/schemas/windows_physical_device_lab_evidence.schema.json).

Minimal shape:

```json
{
  "schema": "casein_windows_physical_device_lab",
  "schema_version": 1,
  "issue": 377,
  "recorded_at_utc": "2026-08-09T00:00:00Z",
  "product_revision": "full-git-sha",
  "operator": "human-id-not-email-required",
  "claims": {
    "physical_android": true,
    "physical_ipad": true,
    "windows_origin_exercised": true,
    "simulator_or_emulator": false,
    "secrets_redacted": true
  },
  "windows_host": {
    "os": "Windows 11",
    "package_signed": true,
    "origin_id_prefix": "a1b2c3d4e5f6",
    "display_name_suffix_ok": true,
    "trusted_lan": "private_rfc1918",
    "profiles_collision_free": true
  },
  "platforms": {
    "android": {
      "device_label": "sm-t390",
      "os_version": "…",
      "app_version": "…",
      "rows": {
        "initial_pair": {"outcome": "passed", "at_utc": "…", "notes": "redacted"},
        "warm_resume_followup": {"outcome": "passed", "at_utc": "…", "notes": ""},
        "background_foreground": {"outcome": "passed", "at_utc": "…", "notes": ""},
        "killed_cold_cached": {"outcome": "passed", "at_utc": "…", "notes": ""},
        "host_restart": {"outcome": "passed", "at_utc": "…", "notes": ""},
        "device_restart": {"outcome": "passed", "at_utc": "…", "notes": ""},
        "offline_firewall_denied": {"outcome": "passed", "at_utc": "…", "notes": ""},
        "vpn_interface_change_repair": {"outcome": "passed", "at_utc": "…", "notes": ""},
        "tampered_target_fail_closed": {"outcome": "passed", "at_utc": "…", "notes": ""},
        "operator_verify_fail_closed": {"outcome": "passed", "at_utc": "…", "notes": ""},
        "pwa_escalation": {"outcome": "passed", "at_utc": "…", "notes": ""}
      }
    },
    "ipad": {
      "device_label": "coding-ipad",
      "os_version": "…",
      "app_version": "…",
      "rows": { "...same keys..." }
    }
  },
  "attachments": {
    "screenshot_count": 0,
    "log_refs": [],
    "issue_comment_urls": []
  },
  "verdict": "matrix_passed"
}
```

Allowed `verdict` values:

| verdict | Meaning | Close #377? |
|---|---|---|
| `matrix_passed` | Both platforms every row `passed`; claims honest | Yes, with JSON attached |
| `matrix_failed` | Schema-valid run with at least one `failed` row | No — product or lab defect |
| `lab_incomplete` | Human stopped early; some `not_run`/`skipped` | No |
| `lab_unreachable_on_this_host` | Self-check only; no devices/Windows origin here | No |
| `rejected_secrets_or_schema` | Validator refused the file | No |

## Composing with related tracks

- Do **not** claim Windows clean-machine or Authenticode in this lab (#376).
- Do **not** claim macOS notarization (#382).
- If the companion will not install, file progress on #416 and leave #377 open.
- Server-side resume/intervene unit tests remain necessary but **insufficient**
  for this issue (already covered under #371 product work).

## Closing #377

1. Attach one schema-valid evidence JSON with `verdict: matrix_passed`.
2. Attach redacted screenshots referenced only by count/labels (no QR).
3. Comment the Windows host revision, both app versions, and OS versions.
4. Run `bash scripts/verify_windows_physical_device_lab.sh --validate-evidence …`
   and paste the exit code / verdict line (not the raw tokens).

Until then, keep `queue/*` state honest: lab definition can land without
devices; matrix completion cannot.
