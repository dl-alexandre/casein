# `mobile_terminal_v1`

Status: frozen for Phase 2 read-only integration.

## Control plane (`mobile:user:me`)

Client events:

- `terminal_create`: `workspace_id`, UUID `request_id`.
- `terminal_refresh`: opaque `lease_id`.
- `terminal_delete`: opaque `lease_id`, UUID `request_id`.

Successful create/refresh replies contain `schema`, `status`, `mode=read`,
`channel_topic`, a metadata-only `lease`, and `child_grant` with the raw token
and `expires_at`. The token is returned once and is never persisted or logged.
Delete replies contain only `schema`, `status=deleted`, and `lease_id`.

Join replies and `cards_snapshot` pushes also carry presentation guidance:

```json
{
  "capabilities": {
    "mobile_terminal": {"enabled": false, "reason": "kill_switch_active"}
  }
}
```

When enabled, `mobile_terminal` is `{"enabled": true}`. This field is not
authority: create/join still require policy + child grant. Clients hide the
Terminal entry point unless `enabled` is true (fail closed when missing or
cached-disabled).

## Byte plane (`mobile_terminal:<lease_id>`)

Join requires `child_grant` and a client-generated `connection_generation`.
The join reply is a `terminal_baseline`; it must be accepted before live output.
`terminal_baseline` and `terminal_output` contain:

- `schema`, `event`, `mode=read`;
- `lease_id`, `lifecycle_generation`, `connection_generation`;
- `stream_generation`, `offset`, `next_offset`;
- `bytes_base64` and `truncated`.

The decoded payload is at most 65,536 bytes. Live frames must match every
generation and begin at the previously accepted `next_offset`. A cutoff emits
`terminal_cutoff` with `lease_id`, `connection_generation`, and a closed reason.

`terminal_input`, `terminal_paste`, and `terminal_query` always reject with
`read_only` in Phase 2.

## Closed errors

`invalid_payload`, `unauthorized`, `not_found`, `unavailable`,
`feature_disabled`, `kill_switch_active`, `policy_denied`, `inactive_origin`,
`stale_lease`, `stale_grant`, `grant_expired`, `grant_revoked`,
`grant_already_used`, `identity_mismatch`, `pane_identity_mismatch`,
`pane_role_mismatch`, `topology_mismatch`, `connection_generation_mismatch`,
`offset_mismatch`, `read_only`.

Unknown internal failures map to `unavailable`. No raw terminal bytes, token,
command, pane contents, or environment values enter errors, audit, or logs.
