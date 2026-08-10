# Windows channel release-gate evidence (#376)

**Authority:** issue #376 (production-sign + clean-machine). Parent checklist #371.
**Extends:** #794 reboot harness + #795 honest claim markers. This doc is the
operator evidence contract; it does not replace those harnesses.

## What this box can and cannot prove

| Claim | Proven by Linux/devbox dry-run? | Requires external host? |
|---|---|---|
| Evidence schema + claim honesty validator exist | Yes (`scripts/verify_windows_release_gate_evidence.sh`) | No |
| Marker/self-test package smoke (`-SelfTestContinuation`) | Yes (package CI) | Not reboot evidence |
| Production Authenticode (`package-windows-desktop.ps1 -RequireSigned`) | **No** | Protected Windows runner + production cert |
| Clean Win11 no tooling/WSL lifecycle JSON | **No** | Disposable clean Windows 11 account |
| Real reboot with `claims.real_reboot=true` | **No** | Disposable host + actual reboot |
| GitHub Actions desktop artifact upload | Build/smoke may pass | Account artifact quota may refuse upload only |

A green `--self-check` / `--dry-run` is **not** release-gate completion. It always
writes `verdict=gate_unreachable_on_this_host` and keeps
`production_signed` / `real_reboot` / `clean_machine_no_tooling` **false**.

## Dry-run (this repo / Linux)

```bash
bash scripts/verify_windows_release_gate_evidence.sh --help
bash scripts/verify_windows_release_gate_evidence.sh --print-operator-steps
bash scripts/verify_windows_release_gate_evidence.sh --print-template > /tmp/376-template.json
bash scripts/verify_windows_release_gate_evidence.sh --dry-run --evidence /tmp/376-self.json
bash scripts/verify_windows_release_gate_evidence.sh --validate-evidence /tmp/376-self.json
```

## External operator path (finish #376)

```bash
bash scripts/verify_windows_release_gate_evidence.sh --print-operator-steps
```

Summary:

1. **Production sign** on a protected Windows runner:
   `scripts/package-windows-desktop.ps1 -SigningCertificateThumbprint <thumb> -RequireSigned`
   then `scripts/test-windows-desktop-package.ps1 -PackageRoot dist\Casein-windows-x64`.
   Write fixture `production_sign.json` (subject, 40-hex thumbprint,
   `require_signed: true`, signed file hashes). **Never** attach private keys or
   certificate passwords.

2. **Clean machine** on disposable Windows 11 (no language tooling, no WSL):
   `windows/Test-CaseinCleanMachine.ps1 -AcceptDestructiveCleanMachineTest -RequireNoDeveloperTooling`.
   Fixture must record `claims.clean_machine_no_tooling=true` and must **not**
   set `real_reboot=true`.

3. **Real reboot** (not `-SelfTestContinuation`):
   `windows/Test-CaseinRebootPersistence.ps1 -Stage prepare` → reboot →
   `-Stage continue`. Attach only when `claims.real_reboot=true` (boot stamp
   changed).

4. Assemble top-level evidence from `--print-template`, set strong claims, point
   `fixture_refs` at the three fixtures, then:

```bash
bash scripts/verify_windows_release_gate_evidence.sh \
  --validate-evidence evidence.json --fixture-dir ./fixtures
```

`release_gate_passed` is accepted only when all three strong claims are true
**and** the matching fixture files validate. True claims without `--fixture-dir`
files are rejected (exit 3) — that is the anti-false-green rule.

## Fixture shapes (operator-produced; fake CI fixtures use obvious placeholders)

**production_sign.json**

```json
{
  "signer_subject": "CN=Example Code Signing (NOT REAL)",
  "signer_thumbprint": "0123456789ABCDEF0123456789ABCDEF01234567",
  "require_signed": true,
  "signed_files": [
    {"path": "Casein.exe", "sha256": "aaa..."}
  ]
}
```

**clean_machine.json** — redacted output (or extract) from
`Test-CaseinCleanMachine.ps1` with `claims.clean_machine_no_tooling=true`.

**real_reboot.json** — redacted output from `Test-CaseinRebootPersistence.ps1`
continue stage with `claims.real_reboot=true`. Must not be self-test output.

Schema pin:
[`scripts/schemas/windows_release_gate_evidence.schema.json`](../../scripts/schemas/windows_release_gate_evidence.schema.json).

## Forbidden evidence

- Closing #376 from Linux/devbox dry-run or package smoke alone
- `claims.production_signed=true` without production_sign fixture
- `claims.real_reboot=true` from `-SelfTestContinuation` or equal boot stamps
- Private keys, cert passwords, API tokens in any JSON string
- Workflow hacks to green desktop artifact upload (account quota is infra)
