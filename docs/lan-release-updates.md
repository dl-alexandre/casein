# LAN release updates

> Operator contract for self-hosted LAN installs: versioned release trees,
> channel-scoped update manifests, and an explicit `casein` CLI update path.
> v1 does **not** silently install updates.

This doc is the authoritative contract for LAN packaging and updates. Devbox
systemd/canary deploys remain documented in
[`integrations/manager.md`](integrations/manager.md) and
[`subsystems/policy_deploy_export.md`](subsystems/policy_deploy_export.md).

## Decisions (locked for v1)

| Topic | Decision |
|-------|----------|
| Update source | Embedded release metadata includes `update_manifest_url`; env override `CASEIN_UPDATE_MANIFEST_URL` wins at check time. |
| Comparison key | `revision` is the update identity. `version` is display-only (Mix app version). |
| Install layout | Versioned release directories plus stable symlinks (see Filesystem shape). |
| Ownership | Release trees owned by `root:root`; the BEAM still runs as the LAN user from `/etc/casein/lan.env`. |
| Privilege | `casein update check` is unprivileged; `casein update install` and `casein update rollback` require `sudo`. |
| Auto-update | No silent install in v1. The UI may show the exact terminal command only. |

## Filesystem shape

Keep compatibility with the current stable path by making it a symlink:

```text
/opt/casein/lan/
  releases/
    504670c/
    67f393a/
  current -> releases/67f393a
  previous -> releases/504670c
  downloads/          # fetched tarballs (install step)

/opt/casein/lan-release -> /opt/casein/lan/current
/etc/casein/lan.env
/etc/casein/lan.public.env
```

Systemd continues to point at the stable path:

```text
WorkingDirectory=/opt/casein/lan-release
ExecStartPre=/opt/casein/lan-release/bin/migrate
ExecStart=/opt/casein/lan-release/bin/casein start
```

`lan-release` preserves the existing mental model while enabling clean rollback via
`previous` → `current` symlink swaps.

## Embedded metadata

Ship inside every LAN release at:

```text
releases/casein.relmeta.json
```

Schema (metadata version 1):

```json
{
  "metadata_version": 1,
  "app": "casein",
  "version": "0.1.0",
  "revision": "504670cdeadbeef...",
  "profile": "lan",
  "repo_adapter": "sqlite",
  "target": "linux-x86_64",
  "channel": "canary",
  "update_manifest_url": "https://github.com/dl-alexandre/casein/releases/latest/download/casein-canary.json",
  "built_at": "2026-07-02T12:00:00Z"
}
```

Build-time env vars (all optional; sensible defaults when unset):

| Variable | Purpose |
|----------|---------|
| `CASEIN_GIT_REVISION` | Git SHA written to `revision` (falls back to `git rev-parse HEAD` in the builder). |
| `CASEIN_RELEASE_PROFILE` | `profile` field (`lan` for LAN tarballs). |
| `CASEIN_RELEASE_REPO_ADAPTER` | `repo_adapter` field (`sqlite` for LAN). |
| `CASEIN_RELEASE_TARGET` | `target` triplet (`linux-x86_64`). |
| `CASEIN_RELEASE_CHANNEL` | `channel` field (`canary`). |
| `CASEIN_UPDATE_MANIFEST_URL` | Default manifest URL embedded in metadata. |

## Remote manifest

Channel-scoped, evolvable JSON published to GitHub Releases (or any HTTPS host):

```json
{
  "manifest_version": 1,
  "channel": "canary",
  "generated_at": "2026-07-02T12:05:00Z",
  "signature": null,
  "artifacts": [
    {
      "app": "casein",
      "version": "0.1.0",
      "revision": "67f393adeadbeef...",
      "profile": "lan",
      "repo_adapter": "sqlite",
      "target": "linux-x86_64",
      "url": "https://github.com/dl-alexandre/casein/releases/download/canary/casein-lan-linux-x86_64-67f393a.tar.gz",
      "sha256": "...",
      "size": 123456789,
      "min_installer_metadata_version": 1,
      "changelog_url": "https://github.com/dl-alexandre/casein/compare/504670c...67f393a"
    }
  ]
}
```

Rules:

- `manifest_version` and `min_installer_metadata_version` gate compatibility; refuse
  when the running installer cannot understand a newer schema.
- Select the artifact whose `profile` + `target` match the installed metadata.
- `signature` is reserved for a future signed-manifest v2; v1 treats `null` as
  unsigned.

## CLI contract

```bash
casein version
casein version --json

casein update check
casein update check --json

sudo casein update install          # Phase 4+
sudo casein update install --to 67f393a
sudo casein update rollback

casein lan status                   # Phase 5+
casein lan status --json
```

`casein version` and `casein update check` are implemented in Phase 1–2.
Install and rollback are implemented in Phase 4. `lan status --json` follows in
Phase 5.

Release-local metadata/update commands set `CASEIN_RELEASE_ROOT` to the wrapper's
release tree and `CASEIN_RELEASE_CLI=1` while invoking `bin/casein eval`. That
keeps read-only operator commands independent of server runtime requirements like
`DATABASE_PATH`, `DATABASE_URL`, and `SECRET_KEY_BASE`.

Human `casein version` example:

```text
casein 0.1.0 (504670c) lan/linux-x86_64 canary
```

Human `casein update check` example when an update exists:

```text
current:  504670c (0.1.0)
available: 67f393a (0.1.0)
channel:  canary
install:  sudo casein update install
```

JSON `casein update check` statuses: `current`, `update_available`, `error`.

## Install algorithm (Phase 4)

1. Read current metadata from `/opt/casein/lan-release/releases/casein.relmeta.json`.
2. Fetch manifest (`CASEIN_UPDATE_MANIFEST_URL` override, else embedded URL).
3. Select artifact matching `profile + target`.
4. Refuse incompatible manifest/installer versions.
5. Download tarball to `/opt/casein/lan/downloads/`.
6. Verify SHA256.
7. Extract to `/opt/casein/lan/releases/<revision>.staging`.
8. Validate staging tree:
   - `bin/casein`, `bin/casein`, `bin/migrate`
   - static assets under `lib/casein-*/priv/static`
   - metadata `profile` / `repo_adapter` / `target`
9. Move staging → `/opt/casein/lan/releases/<revision>`.
10. Point `previous` at old `current`.
11. Point `current` at new release.
12. `systemctl restart casein-lan.service`.
13. Probe:
    - `http://127.0.0.1:$PORT/`
    - `http://$CASEIN_LAN_HOST/`
    - `/assets/css/app.css`
14. On probe failure: roll back symlinks and restart.

Phase 4 intentionally does **not** require `/api/deploy_status`: that endpoint
checks devbox handoff wiring and can fail on a healthy LAN install. A
LAN-neutral authenticated release health endpoint remains a follow-up before
making the dynamic probe mandatory.

## Implementation order

| Phase | Deliverable |
|-------|-------------|
| 1 | Release metadata generation + `casein version` |
| 2 | Manifest parser + `casein update check` |
| 3 | `scripts/package-release.sh` for `lan/linux-x86_64` tarballs + local `dist/casein-canary.json` |
| 4 | `update install` / symlink swap / rollback |
| 5 | `casein lan status --json` + update-awareness line |
| 6 | UI banner showing the exact `sudo casein update install` command |
| 7 | Dogfood on r630, then carbon; milcmini stays manual until launchd/Caddy |

## Code map (Phase 1–4)

| Module | Role |
|--------|------|
| `Casein.Release.Metadata` | Read/write `casein.relmeta.json`; assemble-time writer. |
| `Casein.Release.Update.Manifest` | Parse and validate remote manifest JSON. |
| `Casein.Release.Update.Check` | Compare installed revision vs manifest artifact. |
| `Casein.Release.Update.InstallPlan` | Read-only install planning for the root-owned release wrapper. |
| `Casein.Release.CLI` | `version` and `update check` entrypoints for `bin/casein`. |
| `mix.exs` `write_release_metadata/1` | Release assemble step emitting metadata. |
| `rel/overlays/bin/casein` | Release-local CLI wrapper, LAN systemd install, update install, rollback. |
| `scripts/casein` | Checkout CLI wrapper (`mix run --no-start`). |
| `scripts/package-release.sh` | Build + tarball + sha256 + local manifest generation (Phase 3). |
| `Casein.Release.Package` | Upsert packaged artifacts into `dist/casein-<channel>.json`. |

## Rollout targets

| Host | v1 posture |
|------|------------|
| r630 | First dogfood target after Phase 3 packaging |
| carbon | Second LAN host |
| milcmini | Manual dev mode until launchd + Caddy support exists |
