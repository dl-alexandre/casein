# Gate 0 Dash strict-consumer handoff

Status at 2026-08-27:

- gate_0: producer_validated
- contract: contract-green
- integration: integration-red
- production: forbidden
- No live GitHub, PR, deployment, production, or canary mutation was performed.

This is a handoff manifest, not a schema change. The frozen JSON fixture pack is
unchanged. Dash must consume the exact JSON bytes and select the receipt profile
from the receipt's source and git.outcome; it must not apply the merged
dash_verda profile to a Casein waiting receipt.

## Source of truth

The artifacts are currently present in the OneBackend-v3 checkout below. The
visibility audit found no copy of these files under the Dash checkout on
milcmini (/Users/milc/.dash-site). Do not create a substitute or copy
credentials. The exact files must be made available to the Dash task through
the normal artifact handoff, preserving the listed bytes and checksums.

| Artifact | Repository-relative path | SHA-256 |
| --- | --- | --- |
| Current producer Receipt.build output | docs/operations/casein-v3-worker/producer_receipt_e173f3aff6bacc8d085bfe35fc4c72c7d2261879.json | 7f52fc07ae922d42325e2b391cc06e6b52ac77fe724f1d79d27cc26be1ac7b10 |
| Receipt checksum sidecar | docs/operations/casein-v3-worker/producer_receipt_e173f3aff6bacc8d085bfe35fc4c72c7d2261879.json.sha256 | contains the receipt digest above |
| Frozen Gate 0 fixture pack | docs/operations/casein-v3-worker/gate0_fixture_pack.json | 582bf3bcba6214babcb067a65d906699caf45280f834bd3ec371c3ca7bd7d7aa |
| Official validator | scripts/casein/validate_gate0_fixtures.py | aa832108daf59b29feae1f1ec872cdb19905374a6c59d2ee48fbc3dec7b2f37e |

Absolute source root:

    /Users/developer/Documents/GitHub/workspaces/milc/USER/worktrees/Develop/OneBackend-v3

The older producer_receipt_5456d90b.json remains historical evidence for the
published baseline and is not a substitute for the e173 artifact.

## Producer ref and revalidation

The producer repository is https://github.com/dl-alexandre/casein.git.
The authoritative branch/ref and commit are:

    agent/codex/jido-handoff-actions-20260826
    e173f3aff6bacc8d085bfe35fc4c72c7d2261879

Read-only remote verification returned:

    e173f3aff6bacc8d085bfe35fc4c72c7d2261879  refs/heads/agent/codex/jido-handoff-actions-20260826

The exact e173 checkout was clean and resolved to the same commit. The frozen
pack still records the earlier 5456d90b producer-validation baseline by design;
that metadata was not rewritten. Fresh validation of e173 found no contract or
fixture drift.

Run from the source root:

    python3 scripts/casein/validate_gate0_fixtures.py \
      --producer-output docs/operations/casein-v3-worker/producer_receipt_e173f3aff6bacc8d085bfe35fc4c72c7d2261879.json

Exact result:

    GATE0 FIXTURES: PASS — 5 valid fixtures; 63 vectors
    GATE0 PRODUCER: PASS — profile=casein_waiting
    Gate 0 status: producer_validated; producer compatibility is contract-green.

Checksum verification:

    shasum -a 256 -c docs/operations/casein-v3-worker/producer_receipt_e173f3aff6bacc8d085bfe35fc4c72c7d2261879.json.sha256

Result:

    producer_receipt_e173f3aff6bacc8d085bfe35fc4c72c7d2261879.json: OK

The validator is standard-library-only and does not start Phoenix, contact
GitHub, or change a worktree.

## Exact current Casein waiting receipt

This is the complete current e173 producer artifact. It is a Casein waiting
receipt, not a Dash merged receipt:

~~~json
{"files":[{"path":"README.md"}],"source":"casein_worker","request_id":"request-gate0","workspace_id":"ws-gate0-receipt","runtime_id":"runtime-gate0","git":{"repository":"dl-alexandre/casein","head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","base_branch":"master","release_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","head_branch":"agent/gate0-receipt","merge_actor_ref":null,"merged_sha":null,"outcome":"waiting","post_merge_evidence_ref":null},"session_id":"session-gate0","owner_ref":{"id":"dl-alexandre","role":"operator","provider":"github"},"worker_id":"worker-gate0","workcell_id":"workcell-gate0","authorization":{"decision":"allow","decision_id":"decision-gate0"},"evidence_ref":"evidence-gate0","handoff_id":"handoff-gate0","receipt_id":"receipt-gate0","tests":[{"command":"mix test","status":"passed"}],"contract":{"name":"casein-dash-handoff","version":"1.0"},"idempotency":{"handoff_key":"handoff:v1:handoff-gate0:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"schema_version":1}
~~~

Required interpretation of this artifact:

- source=casein_worker and git.outcome=waiting select the casein_waiting
  profile.
- git.head_sha and git.release_sha are each exactly 40 lowercase hex
  characters. git.merged_sha is JSON null until a verified merge.
- git.pr_number and git.pr_url are absent, not serialized as null, on
  this waiting producer output.
- task_id, lease_id, and correlation_id are absent because this receipt
  was not Mira-originated. Casein must never mint Mira IDs.
- owner_ref is {provider, id, role}. It is not an email or a credential.
- The only handoff idempotency namespace is
  handoff:v1:<handoff_id>:<head_sha>. Review-thread actions use the separate
  review-thread:v1:<handoff_id>:<head_sha>:<opaque_thread_id> namespace.
- Files contain repository-relative paths; commands and test names are typed
  separately. No credentials, tokens, process references, or absolute paths
  are present.

## Profile dispatch boundary

Dash must validate the canonical envelope before projecting any nested Git
fields into its internal handoff shape. Dispatch is exact and has no aliasing
or normalization:

| Receipt source | Git outcome | Profile | Required authority |
| --- | --- | --- | --- |
| v3_casein or casein_worker | waiting | casein_waiting (or mira_waiting only when a real Mira task_id/lease_id/matching correlation_id is present) | Casein/V3 handoff evidence |
| dash_verda | merged | dash_merged (or mira_dash_merged only when explicitly Mira-originated) | Dash/Verda after PR, CI, review, expected-head, and merge verification |

Casein emits waiting evidence only. Dash/Verda is the sole authority for live
PR, CI, review-thread, merge, and deploy operations. A Casein waiting receipt
must not be validated with the merged dash_verda schema. Conversely, a Dash
merged receipt must not be emitted before live expected-head and merge
verification.

waiting and blocked are successful Git receipt outcomes, not error envelopes.
head_sha_changed is a live Git outcome only. Authorization decisions
(allow, deny, hold, revoke) remain separate from Git outcomes.

## Strict-consumer assertions

The Dash consumer must assert all of the following against the frozen pack:

1. schema_version is integer 1, and contract.name/version is
   casein-dash-handoff / 1.0.
2. Gate 0 scalar IDs use the frozen ID pattern only. Repository, branch, URL,
   email, path, command, SHA, and GitHub thread_id remain distinct types;
   GitHub thread IDs are opaque.
3. owner_ref has provider, id, and role; an email cannot be its id.
4. head_sha, release_sha, and merged_sha use
   ^[0-9a-f]{40}$ when present. A waiting receipt has no merged SHA; a
   merged receipt requires a verified merged SHA, merge actor ref, and
   post-merge evidence ref.
5. IDs are conditional by originating lane. task_id is a real Mira turn UUID
   only when Mira originated the operation; lease_id is one execution
   attempt; correlation_id equals task_id when task_id is present.
   oban_job_id is internal and must not cross the boundary.
6. Unknown fields and forbidden aliases are rejected in v1. Do not accept
   git.pushed, top-level merged fields, tests.name, tests.commit_sha,
   composite source aliases, or legacy flat-field normalization.
7. CASEIN_INPUT_MAX_BYTES is exactly 8192.
8. Handoff replay uses the handoff key above; fingerprint mismatch and reuse
   with a new head SHA are rejected. Review-thread action replay uses its own
   key and opaque thread ID. Target-only automatic review-thread resolution
   requires an auditable action record and idempotent replay; it never implies
   content-based approval.
9. Provider/account references are non-secret identity references only.
   Per-operation authorization is checked before the external operation.
10. Error responses use the redacted error envelope. No secrets, tokens,
    credentials, process arguments, absolute paths, or hidden runtime state
    may appear in a receipt or error.

## Frozen invalid-vector manifest

The executable bodies, base documents, mutations, expected error codes, and
mode-specific rules are authoritative in
gate0_fixture_pack.json at fail_vectors. The pack contains exactly 63
vectors. Dash should run them from the pack; this list is the review manifest
and must not be retyped into a second schema.

### Document mode (48)

1. missing_id.receipt_id
2. missing_id.request_id
3. missing_id.owner_ref.id
4. missing_id.workspace_id
5. missing_id.runtime_id
6. missing_id.worker_id
7. missing_id.session_id
8. missing_id.workcell_id
9. missing_id.handoff_id
10. missing_id.task_id
11. missing_id.lease_id
12. missing_id.correlation_id
13. missing_id.action_id
14. invalid_owner_ref
15. email_serialized_on_receipt
16. site_id_as_workspace
17. foreign_lane_id.task_id_on_casein
18. invalid_id.workspace_id
19. invalid_task_id
20. invalid_lease_id
21. source_composite_alias
22. casein_merged_outcome
23. dash_waiting_outcome
24. invalid_git_outcome
25. schema_version_unsupported
26. contract_version_missing
27. unknown_field
28. forbidden_alias
29. git_fields_outside_canonical_object
30. merged_sha_top_level_alias
31. tests_name_alias
32. absolute_path_in_files
33. invalid_sha.head_sha
34. uppercase_sha
35. release_sha_invalid
36. merged_sha_not_allowed
37. merged_sha_required
38. merge_actor_missing
39. merge_actor_ref_invalid
40. post_merge_evidence_missing
41. nonmerged_post_merge_metadata
42. invalid_authorization_decision
43. correlation_mismatch
44. invalid_thread_id
45. content_based_approval
46. dash_identity_mismatch
47. casein_task_absent_is_allowed
48. session_workcell_ids_allowed_by_profile

### Replay mode (5)

49. handoff_key_mismatch
50. idempotency_fingerprint_mismatch
51. reused_handoff_new_sha
52. handoff_key_uses_thread_namespace
53. thread_action_key_uses_handoff_namespace

### Protocol mode (1)

54. input_over_limit

### Live GitHub mode (9)

55. rate_limited
56. unauthorized
57. forbidden
58. not_found
59. unavailable
60. timeout
61. head_sha_changed
62. checks_pending
63. checks_failed

The numbering above is this handoff manifest's grouped order; the
authoritative order and mutation bodies remain in the frozen pack's
fail_vectors array. The two document vectors casein_task_absent_is_allowed and
session_workcell_ids_allowed_by_profile are positive boundary checks despite
being kept in the invalid-vector collection. dash_identity_mismatch is
document validation; head_sha_changed is live GitHub only. input_over_limit
is protocol validation, not receipt validation. missing_id.action_id applies
only to review-thread action documents.

## Dash handoff and next safe verification

The exact coordinator preflight command is the validator command above,
executed with the exact pack and exact e173 receipt. The current Dash checkout
does not yet contain the pack, receipt, checksum sidecar, validator, or a
Gate 0 strict-consumer test target; therefore no Dash-side pass is claimed.

After the exact artifacts are made visible to the Dash task, the safe ordering
is:

1. Verify all listed artifact checksums before reading the receipt; use the
   checksum sidecar to verify the producer receipt.
2. Run the official validator and require the exact PASS output above.
3. Run Dash's strict consumer tests against the same receipt and all 63 pack
   vectors, including profile dispatch, idempotency, exact SHA, and
   no-credential assertions.
4. Exercise authenticated Casein-to-Dash ingress in a disposable environment.
5. Only after those pass, reassess the integration gate. Do not run a live
   canary, real PR, merge, deployment, or production action as part of this
   handoff.

The remaining integration blocker is therefore artifact visibility plus Dash
strict-consumer validation and authenticated ingress. The contract remains
green; integration remains red.
