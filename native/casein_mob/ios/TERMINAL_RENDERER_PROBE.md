# iOS terminal renderer probe

This is a synthetic-only Phase 1B gate for a future native terminal surface.
It is not a terminal transport, does not open a session, and is inert unless
the signed app is launched with `--casein-terminal-probe`.

## Boundary

- `CaseinTerminalRendererProbe.swift` owns a small renderer façade and a
  Canvas implementation for one fixed ANSI fixture.
- The same view is registered through Mob's `MobNativeViewRegistry` only in a
  process launched with the explicit probe flag; no product screen emits the
  component. An ordinary launch neither registers nor presents the probe.
- Fixture pixels are excluded from accessibility. Accessibility contains only
  bounded renderer/lifecycle metrics and the recreate control.
- A UIKit hosting controller installs an opaque cover before presentation and
  shows it synchronously on `willResignActive`; the SwiftUI view carries a
  second inactive-state mask. Mob owns the UIKit scene lifecycle, so SwiftUI
  `scenePhase` is not authoritative. This narrows foreground-transition
  exposure, but the test cannot inspect the OS-owned app-switcher snapshot and
  therefore does not claim proof of snapshot protection.
- There is no SSH, Citadel, SFTP, tmux-control, credential, socket, or Casein
  session dependency in this probe.

## Existing Casein renderer path

Casein already has `GhosttyVtNif`, `Terminal`, `TerminalScreen`, input encoders,
resize handling, and a libghostty-vt archive for Android arm64. The `static_nifs`
configuration deliberately enables that archive for `:android_arm64` only.
There is no reviewed iOS libghostty-vt archive in this repository, so the
existing terminal screen is not an iOS renderer baseline yet. This probe does
not pretend otherwise and does not weaken the platform guard.

## Source provenance evaluation

Evaluated from clean temporary clones on 2026-08-04:

| Source | Revision | Use in Casein |
| --- | --- | --- |
| `h3nock/remux` | `5b05e6f89072997178de5b5dc972ec709e4617a4` | Architecture/input/lifecycle reference only; no code copied |
| `h3nock/remux-ghostty` | `c7ba271f0b7ee2a780634b4cf9498df091315f14` | Attempted source build of libghostty-vt XCFramework |

The Remux prebuilt GhosttyKit binary was not downloaded, linked, or accepted as
a production dependency. Its release asset is large and its binary-to-source
provenance is not a sufficient Casein production pin.

The source command was:

```sh
mise exec zig@0.15.2 -- zig build \
  -Demit-lib-vt \
  -Demit-macos-app=false \
  -Doptimize=ReleaseFast
```

The checkout requires Zig 0.15.2. On the only available Xcode 27 beta/macOS 27
toolchain, that compiler cannot link its host build runner and stops before
compiling Ghostty with missing Darwin/libSystem symbols including
`__availability_version_check`, `_dispatch_queue_create`, `_clock_gettime`, and
`_abort`. Setting `MACOSX_DEPLOYMENT_TARGET=15.0` does not change the result.
Zig 0.16.0 cannot be substituted: the source intentionally rejects it and its
Build API has changed. A reproducible source-built Ghostty XCFramework is
therefore blocked on a compatible Zig 0.15.2 host toolchain (for example a
supported stable Xcode/macOS SDK pair), not on Casein integration code.

## Signed physical result

Device: Coding iPad, iPad12,1 (9th generation), iOS 27.0, wired. The app was
updated in place with the existing development identity and profile; app data
was not cleared.

| Observation | Result |
| --- | --- |
| Native compile/link/sign/install | pass |
| Fixed ANSI first surface mount (`onAppear`) | 41.10 ms (single physical observation; not a committed-frame measurement) |
| Create/destroy/recreate cycles | 10 automatic + 1 UI-driven, pass |
| Background/foreground lifecycle | pass; OS-owned app-switcher snapshot not asserted |
| Portrait/landscape/portrait | pass |
| Fixture absent from all enumerated accessibility labels/values/identifiers | pass |
| Signed XCUITest | 2/2 pass, flagged lifecycle/privacy-boundary coverage plus an unflagged-launch absence proof in `CaseinTerminalRendererProbeUITests` |
| Installed `.app` size | 185,420 KiB (non-slim development bundle) |
| Main executable size | 9,700,304 bytes |
| Reported RSS delta | 62,570,496 bytes |

The RSS delta is diagnostic only: the baseline is taken while the bundled BEAM
runtime is still starting, so it is not renderer-isolated and must not be used
to compare Canvas with GhosttyKit. No IPA was produced by this development
install. A fair comparison requires the source-built Ghostty candidate, the
same fixture/cycle harness, repeated samples, and renderer-isolated allocation
instrumentation.

## Decision

The Casein-owned façade and Mob/UIKit lifecycle seam pass the signed iPad gate.
Canvas remains the only accepted iOS probe renderer. Do not adopt Remux's SSH
stack or prebuilt GhosttyKit. The next renderer comparison is specifically:

1. source-build and pin libghostty-vt/GhosttyKit on a compatible toolchain;
2. place it behind `CaseinTerminalRendererFacade` without transport changes;
3. repeat this exact synthetic lifecycle/accessibility gate;
4. compare repeated committed-frame timing, renderer-isolated memory, and signed bundle
   size before selecting it.
