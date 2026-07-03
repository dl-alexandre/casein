# LAN release updates

> Operator contract for self-hosted LAN installs: versioned release trees,
> channel-scoped update manifests, and an explicit `devide` CLI update path.
> v1 does **not** silently install updates.

This doc is the authoritative contract for LAN packaging and updates. Devbox
systemd/canary deploys remain documented in
[`integrations/manager.md`](integrations/manager.md) and
[`subsystems/policy_deploy_export.md`](subsystems/policy_deploy_export.md).

## Decisions (locked for v1)

| Topic | Decision |
|-------|----------|
| Update source | Embedded release metadata includes `update_manifest_url`; env override `DEVIDE_UPDATE_MANIFEST_URL` wins at check time. |
| Comparison key | `revision` is the update identity. `version` is display-only (Mix app version). |
| Install layout | Versioned release directories plus stable symlinks (see Filesystem shape). |
| Ownership | Release trees owned by `root:root`; the BEAM still runs as the LAN user from `/etc/devide/lan.env`. |
| Privilege | `devide update check` is unprivileged; `devide update install` and `devide update rollback` require `sudo`. |
| Auto-update | No silent install in v1. The UI may show the exact terminal command only. |

## Filesystem shape

Keep compatibility with the current stable path by making it a symlink:

```text
/opt/devide/lan/
  releases/
    504670c/
    67f393a/
  current -> releases/67f393a
  previous -> releases/504670c
  downloads/          # fetched tarballs (install step)

/opt/devide/lan-release -> /opt/devide/lan/current
/etc/devide/lan.env
/etc/devide/lan.public.env
```

Systemd continues to point at the stable path:

```text
WorkingDirectory=/opt/devide/lan-release
ExecStartPre=/opt/devide/lan-release/bin/migrate
ExecStart=/opt/devide/lan-release/bin/dev_ide start
```

`lan-release` preserves the existing mental model while enabling clean rollback via
`previous` → `current` symlink swaps.

## Embedded metadata

Ship inside every LAN release at:

```text
releases/dev_ide.relmeta.json
```

Schema (metadata version 1):

```json
{
  "metadata_version": 1,
  "app": "devide",
  "version": "0.1.0",
  "revision": "504670cdeadbeef...",
  "profile": "lan",
  "repo_adapter": "sqlite",
  "target": "linux-x86_64",
  "channel": "canary",
  "update_manifest_url": "https://github.com/dl-alexandre/dev_ide/releases/latest/download/devide-canary.json",
  "built_at": "2026-07-02T12:00:00Z"
}
```

Build-time env vars (all optional; sensible defaults when unset):

| Variable | Purpose |
|----------|---------|
| `DEVIDE_GIT_REVISION` | Git SHA written to `revision` (falls back to `git rev-parse HEAD` in the builder). |
| `DEVIDE_RELEASE_PROFILE` | `profile` field (`lan` for LAN tarballs). |
| `DEVIDE_RELEASE_REPO_ADAPTER` | `repo_adapter` field (`sqlite` for LAN). |
| `DEVIDE_RELEASE_TARGET` | `target` triplet (`linux-x86_64`). |
| `DEVIDE_RELEASE_CHANNEL` | `channel` field (`canary`). |
| `DEVIDE_UPDATE_MANIFEST_URL` | Default manifest URL embedded in metadata. |

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
      "app": "devide",
      "version": "0.1.0",
      "revision": "67f393adeadbeef...",
      "profile": "lan",
      "repo_adapter": "sqlite",
      "target": "linux-x86_64",
      "url": "https://github.com/dl-alexandre/dev_ide/releases/download/canary/devide-lan-linux-x86_64-67f393a.tar.gz",
      "sha256": "...",
      "size": 123456789,
      "min_installer_metadata_version": 1,
      "changelog_url": "https://github.com/dl-alexandre/dev_ide/compare/504670c...67f393a"
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
devide version
devide version --json

devide update check
devide update check --json

sudo devide update install          # Phase 4+
sudo devide update install --to 67f393a
sudo devide update rollback

devide lan status                   # Phase 5+
devide lan status --json
```

`devide version` and `devide update check` are implemented in Phase 1–2.
Install and rollback are implemented in Phase 4. `lan status --json` follows in
Phase 5.

Release-local metadata/update commands set `DEVIDE_RELEASE_ROOT` to the wrapper's
release tree and `DEV_IDE_RELEASE_CLI=1` while invoking `bin/dev_ide eval`. That
keeps read-only operator commands independent of server runtime requirements like
`DATABASE_PATH`, `DATABASE_URL`, and `SECRET_KEY_BASE`.

Human `devide version` example:

```text
devide 0.1.0 (504670c) lan/linux-x86_64 canary
```

Human `devide update check` example when an update exists:

```text
current:  504670c (0.1.0)
available: 67f393a (0.1.0)
channel:  canary
install:  sudo devide update install
```

JSON `devide update check` statuses: `current`, `update_available`, `error`.

## Install algorithm (Phase 4)

1. Read current metadata from `/opt/devide/lan-release/releases/dev_ide.relmeta.json`.
2. Fetch manifest (`DEVIDE_UPDATE_MANIFEST_URL` override, else embedded URL).
3. Select artifact matching `profile + target`.
4. Refuse incompatible manifest/installer versions.
5. Download tarball to `/opt/devide/lan/downloads/`.
6. Verify SHA256.
7. Extract to `/opt/devide/lan/releases/<revision>.staging`.
8. Validate staging tree:
   - `bin/devide`, `bin/dev_ide`, `bin/migrate`
   - static assets under `lib/dev_ide-*/priv/static`
   - metadata `profile` / `repo_adapter` / `target`
9. Move staging → `/opt/devide/lan/releases/<revision>`.
10. Point `previous` at old `current`.
11. Point `current` at new release.
12. `systemctl restart devide-lan.service`.
13. Probe:
    - `http://127.0.0.1:$PORT/`
    - `http://$DEV_IDE_LAN_HOST/`
    - `/assets/css/app.css`
14. On probe failure: roll back symlinks and restart.

Phase 4 intentionally does **not** require `/api/deploy_status`: that endpoint
checks devbox handoff wiring and can fail on a healthy LAN install. A
LAN-neutral authenticated release health endpoint remains a follow-up before
making the dynamic probe mandatory.

## Implementation order

| Phase | Deliverable |
|-------|-------------|
| 1 | Release metadata generation + `devide version` |
| 2 | Manifest parser + `devide update check` |
| 3 | `scripts/package-release.sh` for `lan/linux-x86_64` tarballs + local `dist/devide-canary.json` |
| 4 | `update install` / symlink swap / rollback |
| 5 | `devide lan status --json` + update-awareness line |
| 6 | UI banner showing the exact `sudo devide update install` command |
| 7 | Dogfood on r630, then carbon; milcmini stays manual until launchd/Caddy |

## Code map (Phase 1–4)

| Module | Role |
|--------|------|
| `DevIDE.Release.Metadata` | Read/write `dev_ide.relmeta.json`; assemble-time writer. |
| `DevIDE.Release.Update.Manifest` | Parse and validate remote manifest JSON. |
| `DevIDE.Release.Update.Check` | Compare installed revision vs manifest artifact. |
| `DevIDE.Release.Update.InstallPlan` | Read-only install planning for the root-owned release wrapper. |
| `DevIDE.Release.CLI` | `version` and `update check` entrypoints for `bin/devide`. |
| `mix.exs` `write_release_metadata/1` | Release assemble step emitting metadata. |
| `rel/overlays/bin/devide` | Release-local CLI wrapper, LAN systemd install, update install, rollback. |
| `scripts/devide` | Checkout CLI wrapper (`mix run --no-start`). |
| `scripts/package-release.sh` | Build + tarball + sha256 + local manifest generation (Phase 3). |
| `DevIDE.Release.Package` | Upsert packaged artifacts into `dist/devide-<channel>.json`. |

## Rollout targets

| Host | v1 posture |
|------|------------|
| r630 | First dogfood target after Phase 3 packaging |
| carbon | Second LAN host |
| milcmini | Manual dev mode until launchd + Caddy support exists |
