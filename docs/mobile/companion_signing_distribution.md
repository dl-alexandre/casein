# Companion signing, install, and physical distribution (#416)

Status: **in-repo contract locked**; physical distribution remains operator work.

This runbook is the durable operator checklist for external companion signing
and install. It does **not** claim device install, App Store / Play upload,
Gatekeeper notarization, or push delivery. Those require Account Holder action,
real credentials kept off-repo, and hardware that this Linux/devbox cannot
reach. **Physical distribution cannot be completed from this box.**

Related foundations:

| Landed | What it unlocked |
|---|---|
| #424 / PR #793 | Debug vs Release entitlement split on `Provision.xcodeproj` — development push + `get-task-allow` cannot leak into App Store signing |
| #409 | Android data-preserving `adb install -r` (no uninstall fallback on storage failure) |
| #795 / #796 | Adjacent **desktop** release gate / evidence tracks — do not conflate with companion Mob |

## What the repo already proves (no device)

Run from the Casein checkout:

```bash
bash scripts/verify-companion-signing-contract.sh
bash scripts/verify-companion-signing-contract.sh --json /tmp/companion-signing.evidence.json

# External prereq checklist (structured NEED codes; no secrets):
bash scripts/verify-companion-external-prereqs.sh --dry-run
bash scripts/verify-companion-external-prereqs.sh --dry-run --json /tmp/companion-external.evidence.json
# Enforce mode (operator Mac): exits non-zero until CASEIN_COMPANION_* markers are set
# after real material exists. Markers are presence-only — never commit their values.
bash scripts/verify-companion-external-prereqs.sh

# Fixture-only validator (synthetic plists; cheap pre-push guard):
bash scripts/verify-companion-fixtures.sh
bash scripts/verify-companion-fixtures.sh --json /tmp/companion-fixtures.evidence.json
```

Or the ExUnit wrappers (Linux-safe):

```bash
mix test test/scripts/companion_signing_contract_test.exs \
  test/scripts/companion_external_prereqs_test.exs \
  test/scripts/companion_fixtures_test.exs
```

`--dry-run` always lists stable NEED codes (`APPLE_AGREEMENT`, `IOS_DEV_PROFILE`,
`IOS_PHYSICAL_INSTALL`, …) and exits 0 when fixtures + the in-repo contract are
green. It does **not** claim physical install. Enforce mode turns those NEED
lines into a non-zero exit until an operator sets the matching
`CASEIN_COMPANION_*` env markers on a machine that actually holds the material.

The contract asserts:

1. **iOS Debug** (`CaseinMob.entitlements`): `aps-environment=development`,
   `get-task-allow=true`, bundle `com.alexandrefamilyfarm.casein-mob`.
2. **iOS Release** (`CaseinMob.Release.entitlements`): `aps-environment=production`,
   **no** `get-task-allow`, `beta-reports-active`, Apple Distribution + App Store
   profile specifier on the Release configuration only.
3. **Public product name** is **Casein** (`CFBundleDisplayName`, Android `app_name`)
   without changing routing identity (`com.alexandrefamilyfarm.casein-mob` /
   `com.example.casein_mob`).
4. **Secret paths** are gitignored and untracked: `*.mobileprovision`, `*.p12`,
   `AuthKey_*.p8`, `google-services.json`, `android/keystore.properties`,
   `android/*.keystore`.
5. Fixtures under `native/casein_mob/test/fixtures/` are **obviously fake**
   synthetic plists for generator/contract tests — never real profiles.

CI desktop jobs may still red on GitHub Actions **artifact storage quota**
(`Failed to CreateArtifact`) after green build/sign/verify steps. That is an
account-level limit; do not weaken workflows to force green, and do not treat a
quota red as a signing failure.

## Operator steps that remain (hardware / Account Holder)

Do these on a Mac with Xcode, the connected devices, and credentials already in
a secure keychain — **never** paste certs, profiles, team secrets, notary
passwords, or API keys into the repo, PR, or issue comments.

### A. Apple — development install (iPad / iPhone)

1. **Account Holder** accepts the pending Apple Developer / App Store Connect
   Program License Agreement. Until this lands, `mix mob.provision` / xcodebuild
   exit 65 is expected and is **not** a product defect.
2. In the developer portal, create a **dedicated** iOS **Development**
   provisioning profile for App ID `com.alexandrefamilyfarm.casein-mob`
   (team id already on the public App ID record in the checked-in project).
   - Enable **Push Notifications**.
   - Entitlement must include `aps-environment=development`.
   - Include the Coding iPad and DairyPhoneDeaux device UDIDs.
   - **Do not** substitute the team wildcard profile — it lacks push and yields
     install error `0xe8008015`.
3. Download the `.mobileprovision` to the Mac only. Install into Xcode.
   Confirm Debug still points at `CaseinMob.entitlements` (Automatic signing is
   fine once the dedicated profile exists).
4. Build/sign the exact source SHA under test. Install on both devices
   **without** weakening entitlements.
5. Physical matrix (record privately; no tokens/message bodies in tickets):
   - portrait / landscape / keyboard
   - warm resume / cold launch / force-quit
   - origin card / offline / stale-card
   - Evidence Handoff
   - intervention + idempotent replay

### B. Apple — distribution / Gatekeeper (macOS host archive is sibling #382)

Companion **iOS App Store** distribution uses Release entitlements + the store
profile specifier already pinned in `Provision.xcodeproj`. Notarization of the
**macOS Developer ID** desktop archive is tracked on #382 / PR #796 — use that
harness (`notarize-macos-desktop.sh`, `CASEIN_NOTARY_DRY_RUN=1` offline). For
any notarytool profile:

```text
# On the release Mac only — profile name is local keychain metadata.
xcrun notarytool store-credentials "<local-profile-name>"
# then package → notarize → staple → spctl assess
```

Never export the API key / app-specific password into git or CI logs.

Confirm App Store Connect **public product name** is **Casein**.

### C. Android — data-preserving install (SM-T390)

1. Free sufficient storage on the device **without** deleting Casein user data
   or unrelated apps. Prior evidence: `/data` ~96% full (~455 MB free) rejected
   the package installer before session creation
   (`INSTALL_FAILED_INSUFFICIENT_STORAGE`).
2. Install with the preserve-data path only (`adb install -r` / `mix mob.deploy`
   after #409). Never uninstall-to-recover on a paired device.
3. Confirm launcher label **Casein** and complete origin / resume / evidence /
   intervention matrix on-device.
4. Play upload-key material lives only in gitignored
   `native/casein_mob/android/keystore.properties` + `*.keystore` (generated by
   `mix mob.setup.google_play` on an operator machine). Confirm Google Play
   Console public product name is **Casein**.

### D. Push delivery (APNs / FCM)

Validate only after platform profiles/tokens exist, using credentials already
in secure host config (`CASEIN_APNS_*`, Firebase). See
`docs/subsystems/push_notifications.md`. Confirm token lifecycle UX without
exposing tokens, message bodies, terminal output, or evidence contents.

### E. Local cross-origin physical step

1. Wake/unlock the **Local Mac** display and aim the SM-T390 scanner at the
   real Casein pairing QR (no synthetic credential in ADB/logs).
2. Complete Devbox ↔ Local Mac switching, live/cached/offline recovery, Evidence
   Handoff / PWA escalation, and role-marked disposable agent-pane
   intervention/replay.
3. **Do not** focus, type into, restart, close, or otherwise mutate a Devbox
   operator pane during this validation.

## Honesty matrix

| Claim | Proven by this repo alone? |
|---|---|
| Debug/Release entitlement split cannot silently collapse | **Yes** — contract script + `ios_configuration_test` |
| Public launcher/display name is Casein | **Yes** — Info.plist + `strings.xml` |
| Secret material is not tracked | **Yes** — gitignore + `git ls-files` scan |
| Dedicated push-capable iOS development profile installed | **No** — Account Holder + portal |
| Physical iOS/Android install + lifecycle matrix | **No** — devices |
| Gatekeeper notarization / Play upload | **No** — release Mac / Play console |
| APNs/FCM delivery | **No** — live credentials + devices |
| Cross-origin physical pairing | **No** — unlocked Local Mac + scanner |

When an operator finishes a row above, comment the **outcome and SHA** on #416 —
not the profile bytes, notary password, or device token.
