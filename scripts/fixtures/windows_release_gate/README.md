# Windows release-gate fixture examples (#376)

These `*.example.json` files document **shape only**. They set
`example_only: true` and `not_real: true`.

`scripts/verify_windows_release_gate_evidence.sh --validate-evidence` **rejects**
any strong claim (`production_signed`, `real_reboot`, `clean_machine_no_tooling`)
whose fixture carries those flags or a signer subject containing `NOT REAL`.

Do not rename them into operator evidence. Produce real fixtures on a protected
Windows runner / disposable clean Win11 host per
`docs/desktop/windows_release_gate_evidence.md`.
