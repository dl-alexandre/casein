# Release smoke gate

**Status:** Active

**Owner:** Release engineering

**Last updated:** 2026-08-01

The required pull-request gate runs `scripts/pre-push-check.sh` and then a
workspace-contained release smoke. Keeping both phases in the existing `gate`
job lets the release phase reuse the self-hosted runner's `_build` and npm
caches instead of queueing a second slow runner job.

## Release-only coverage

Comparing `scripts/pre-push-check.sh` with `scripts/build-release.sh`, the
`Dockerfile` builder, the `casein.release.lan` Mix alias, and the packaging step
in `scripts/deploy-poller.sh` leaves these operations unique to the release
path:

1. A production (`MIX_ENV=prod`) compile.
2. Production npm installation for both `assets/` and `priv/scripts/`.
3. Tailwind and esbuild minification followed by `phx.digest`.
4. OTP release assembly, including the Casein release steps that validate
   static assets and module names, preserve the generated runtime entrypoint,
   install operator overlays, prune duplicate `erlexec` ports, write release
   metadata, and copy the reviewed release documentation.
5. Tar packaging and extraction, followed by inspection of executables,
   metadata, digested assets, and the release-local Playwright bridge.
6. Platform-dependent ad-hoc signing of Bun binaries on Darwin.
7. Installation of the Playwright Chromium browser payload after activation.

The smoke exercises items 1–5. Item 6 is explicitly skipped on the Linux
runner because it is a Darwin-only operation. Item 7 is explicitly limited to
validating the packaged Playwright CLI: downloading Chromium is already covered
by the dedicated preview E2E workflow and would add a large, user-home browser
cache on the nearly-full self-hosted runner.

The activation half of `scripts/deploy-devbox-release.sh` is deliberately out
of scope. It reads live secrets, migrates the live database, creates and stops
systemd units, swaps the production socket, patches Caddy, and removes release
backups. Those are deploy operations, not safe PR smoke operations.

## Local use

Run the smoke with the repository-pinned toolchain:

```bash
MIX="mise exec -- mix" bash scripts/release-smoke.sh
```

All temporary archives and extraction directories are created below `_build/`
and removed on exit. Generated release/static trees and npm directories are
removed when they did not exist before the run, preserving caches that the
persistent runner already owned.
