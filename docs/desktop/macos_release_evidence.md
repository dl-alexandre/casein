# macOS desktop release evidence (#382)

Operator runbook for **build → Developer ID sign → notarize/staple → lifecycle
evidence** of the Casein menu-bar desktop channel. Source-level tests and the
ad-hoc CI smoke in `.github/workflows/macos-desktop.yml` are necessary but not
sufficient to close #382.

## What counts as release evidence

| Required | Not enough |
|---|---|
| Clean tagged (or clean HEAD) revision packaged on Darwin | Dirty tree with `CASEIN_ALLOW_DIRTY_PACKAGE=1` |
| `Developer ID Application` signature + hardened runtime | Ad-hoc `codesign -s -` CI smoke |
| Notarized + stapled archive/app; `spctl` + `stapler validate` green | `codesign --verify` alone |
| First-launch / login-item / lifecycle notes on a clean supported macOS | Linux-only script syntax tests |
| Immutable hashes + Team ID + redacted logs attached to the issue/release | Relying only on `actions/upload-artifact` |

Do **not** close #382 from an unsigned artifact, a workflow that never acquired
a macOS runner, or a job that is red only because GitHub Actions artifact
storage quota rejected the upload step after a green build/sign/verify.

## Artifact storage quota (known infrastructure blocker)

Desktop jobs have failed with:

```text
##[error]Failed to CreateArtifact: Artifact storage quota has been hit.
```

Signature of the failure: build, sign, and verify steps complete; only
`upload-artifact` fails. The binding limit is **account-level**, not
repo-level. This repo already caps desktop retention at **7 days** in both
`macos-desktop.yml` and `windows-desktop.yml` (#672). Pruning this repo alone
cannot clear an account quota.

**Design around it:** `scripts/package-macos-desktop.sh` writes
`*.evidence.json` beside the zip under
`native/casein_menubar/build/artifacts/`. Operators copy that JSON (and the
zip/sha256/manifest) off the runner or release Mac. Do not hack the workflow
to skip verification just to go green.

## Secrets rule

Never commit a real:

- Developer ID certificate / private key / `.p12`
- provisioning profile
- Team ID paired with a notarization password
- App Store Connect API key (`.p8`) or app-specific password
- notarytool keychain export

Repository fixtures and tests use **obviously fake** values only
(`Developer ID Application: Example Casein Test (AB12CD34EF)`,
`CASEIN_NOTARY_DRY_RUN=1`, etc.).

## Prerequisites (release Mac)

- Apple Silicon and/or Intel Mac as required by the ship matrix
- Xcode CLT with `codesign`, `xcrun notarytool`, `stapler`, `spctl`
- Developer ID Application identity in the login keychain
- Notarization credentials stored as a keychain profile (preferred):

```bash
xcrun notarytool store-credentials casein-notary \
  --apple-id 'operator@example.com' \
  --team-id 'AB12CD34EF' \
  --password '<app-specific-password-from-appleid.apple.com>'
```

Confirm identity without printing secrets:

```bash
security find-identity -v -p codesigning
```

## Production package (signed)

```bash
git status --porcelain   # must be clean for release evidence
export CASEIN_CODESIGN_IDENTITY='Developer ID Application: Example Org (TEAMID)'
export CASEIN_REQUIRE_DEVELOPER_ID=1
scripts/package-macos-desktop.sh
scripts/test-macos-desktop-package.sh --require-developer-id
scripts/verify-macos-desktop-release.sh --require-developer-id --require-hardened-runtime
```

Optional notarization of the zip:

```bash
export CASEIN_NOTARY_KEYCHAIN_PROFILE=casein-notary
scripts/notarize-macos-desktop.sh native/casein_menubar/build/artifacts/Casein-*-macos-*.zip
scripts/test-macos-desktop-package.sh --require-developer-id --require-notarized
```

Evidence JSON (also written automatically at package time):

```bash
scripts/collect-macos-desktop-evidence.sh \
  --app 'native/casein_menubar/build/Casein MenuBar.app' \
  --archive native/casein_menubar/build/artifacts/Casein-*-macos-*.zip
```

Linux / pre-operator dry-run (never claims success):

```bash
scripts/collect-macos-desktop-evidence.sh --dry-run \
  --out /tmp/casein-macos-dry-run.evidence.json
# → result=incomplete
# → missing: ["developer_id","notary_profile","signed_lifecycle"]
# → prints NEED (human): … checklist lines

scripts/validate-macos-desktop-evidence.sh --print-needs \
  /tmp/casein-macos-dry-run.evidence.json
```

`validate-macos-desktop-evidence.sh` rejects:

- incomplete documents with empty/absent `missing[]` (silent pass)
- `passed_release` without Developer ID + hardened runtime + `spctl=accepted` + `stapler=valid` + archive sha256
- any evidence embedding certificate/private-key material

`result` values:

| `result` | Meaning |
|---|---|
| `passed_release` | Developer ID + Gatekeeper accept + staple valid **and** operator lifecycle attested (`CASEIN_LIFECYCLE_ATTESTED=1`) |
| `signed_unnotarized` | Developer ID present; notarization still required for #382 |
| `adhoc_smoke_only` | CI/local smoke — not release evidence |
| `blocked` | Collected off Darwin (host stub only) |
| `failed` / `incomplete` | Fix before publishing; `missing[]` lists NEED codes |

Canonical `missing[]` codes (dry-run / pre-operator): `developer_id`, `notary_profile`, `signed_lifecycle`.

## Lifecycle checklist (operator, clean Mac)

After a notarized install from the zip (not from the build tree):

1. First launch via Finder; confirm menu-bar host + `/desktop/health`
2. Start at Login (`SMAppService`) survives sign-out/in
3. Stop / Restart / Quit leave-server-running behaviors
4. Support log / data folder open actions
5. Uninstall / remove Application Support cleanup
6. Record Intel vs Apple Silicon scope explicitly if one arch is skipped

## CI smoke vs release gate

`.github/workflows/macos-desktop.yml` builds an **ad-hoc** package on the
self-hosted macOS runner (and a hosted matrix on `workflow_dispatch`). That job
proves packaging structure, nested Mach-O codesign, LaunchServices launch, and
auth smoke. It does **not** substitute for Developer ID + notarization evidence
on #382.

Sibling Windows production-sign gate: issue #376 — do not duplicate Windows
files here.

## Entrypoints

| Script | Role |
|---|---|
| `scripts/package-macos-desktop.sh` | Build zip + sha256 + manifest + evidence JSON |
| `scripts/test-macos-desktop-package.sh` | Structure, launch, auth; optional `--require-developer-id` / `--require-notarized` |
| `scripts/verify-macos-desktop-release.sh` | Deep codesign / hardened runtime / spctl / stapler |
| `scripts/notarize-macos-desktop.sh` | `notarytool submit` + staple (`CASEIN_NOTARY_DRY_RUN=1` offline) |
| `scripts/collect-macos-desktop-evidence.sh` | Immutable JSON for the issue/release (`--dry-run` = incomplete + explicit `missing[]`) |
| `scripts/validate-macos-desktop-evidence.sh` | Schema + honesty gate; prints NEED codes; rejects silent pass / overclaim |
| `native/casein_menubar/Resources/Casein.entitlements` | Hardened-runtime entitlements for Developer ID |
| `native/casein_menubar/scripts/bundle.sh` | Nested Mach-O sign; runtime+timestamp when identity ≠ `-` |
