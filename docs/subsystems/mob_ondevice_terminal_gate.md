# Mob on-device terminal — the device gate (research + progress)

> Companion to [`ghostty_terminal_contract.md`](ghostty_terminal_contract.md)
> (the verified terminal contract) and
> `contrib/mob-tooling/TERMINAL-INTEGRATION-SKETCH.md` (the native design). Those
> establish that the on-device IDE terminal is **Model B** — ghostty owns the VT
> state machine + grid; the view renders `cells/1`. This doc resolves the §7
> *fence* both left open: **can the ghostty NIF actually run on iOS/Android?**
>
> **Status: DEVICE GATE CROSSED (Android arm64).** `libghostty-vt` is built for
> `aarch64-linux-android`, statically linked into the MobNode app via a project
> Zigler NIF (`CaseinMob.Nifs.GhosttyVt`), and **verified running on a real arm64
> tablet** (SM-T577U): on-device `nif_new` → `nif_vt_write("DEVICE_VT_OK 42")` →
> `nif_snapshot` returned `"DEVICE_VT_OK 42"`. The `unknown application: :ghostty`
> crash is gone. Getting here took **5 patches to the `GenericJam/zigler`
> `zig-016-port` fork** (it supported iOS static NIFs but never Android) and **1
> `mob_dev` extension** (`:extra_static_libs`) — see §8 for the exact upstream PRs.
> **Remaining (not the gate):** rewire `TerminalScreen` to call this NIF on-device
> (it still uses `ghostty_ex` everywhere); the host↔device byte transport
> (Model-B-over-the-wire); the on-device `Canvas` painter; and iOS (needs a
> macOS-15 build host for the xcframework). `nif_render_cells` hit a `:badarg`
> on-device (render-state path) — `nif_snapshot` works, so investigate or prefer
> snapshot. See §4–§8.

## 1. The reframe: VT engine ≠ PTY (the most important finding)

ghostty's NIF is really **two halves**, with very different mobile stories:

| Half | What it is | Mobile story |
|---|---|---|
| **`libghostty-vt` → `Ghostty.Terminal`** | VT parser + grid/state machine; `write/2` bytes in, `cells/1` grid out | **Portable.** Verified pure, zero-dependency, *libc-free* VT logic (`ghostty-org/ghostty/src/terminal/`). Already embedded in production iOS apps (Echo, Geistty, Termini). **This is what the device needs.** |
| **`Ghostty.PTY` → `forkpty` + exec a shell** | spawns `/bin/sh` on a real PTY | **Does not belong on-device.** iOS App-Store sandboxing forbids spawning child processes (why iOS terminals embed interpreters, not fork shells); Android allows exec but a dev shell isn't there anyway. |

**Consequence — the gate is narrower than "port ghostty."** The device only needs
the **VT-parser NIF** rendering `cells/1`. The **shell/PTY runs on the host** (the
devbox casein `SessionOwner`) and streams bytes over Mob distribution to the
device's terminal — exactly the **Model-B-over-the-wire** the contract (§3) and
the screen moduledoc already name as the fallback. The on-device target is
therefore: **`libghostty-vt` (Terminal half only) static-linked on-device, fed
host-streamed PTY bytes.** No on-device `forkpty`.

## 2. Why the first deploy crashed (verified, file-cited)

Mob has **no generic "build every dep NIF for target" step**. A NIF reaches a
device binary by exactly one of two routes, and ghostty is in neither:

1. **Hardcoded special-case** in the build templates — today *only* exqlite/sqlite
   (`android/app/src/main/jni/build.zig:376-418` links `libsqlite3_nif.so` into
   `jniLibs/<abi>/`; `deps/mob_dev/.../native_build.ex:3007` static-links it for
   iOS). That's why `libsqlite3_nif.so` shipped and ghostty didn't.
2. **The `:static_nifs` allow-list** (`MobDev.StaticNifs`) — cross-compiles
   **project-local** NIFs (C / Rust / Zigler stub *in the app's own tree*), per
   `classify_project_nif/2` (`native_build.ex:3478`).

ghostty fails every gate: it's `ZiglerPrecompiled` (Mob has zero support for that),
lives in `deps/` not the project tree, has no `static_nifs` entry, and isn't
hardcoded. Its `priv/lib/libghostty-vt.a` is **host macOS arm64 only** and the dep
ships **no `build.zig`/source** to rebuild it. Hence on-device the NIF on-load
calls `Application.app_dir(:ghostty)` on an unloaded app → `unknown application:
:ghostty`.

## 3. The blessed path (resolves the iOS "is it wired?" question)

Use **`mix mob.add_nif <name> --type zigler`** — it scaffolds a **project-local**
Zigler NIF, adds a `:static_nifs` entry, and regenerates
`priv/generated/driver_tab_{ios,android}.c`. Critically, the iOS build **does**
wire project Zigler NIFs: `native_build.ex` calls `project_nif_zig_args(:ios_sim)`
/ `(:ios)`, and `:archs` accepts `:ios`, `:ios_device`, `:ios_sim`, `:android`,
`:android_arm64`, `:android_arm32`.

> The `native_build.ex:2498` comment "zig plugin NIFs on iOS aren't wired yet"
> refers to **plugin** (dep-based) zig NIFs — *not* the **project** path used by
> `mob.add_nif --type zigler`, which is wired for iOS. This is why we vendor a
> project-local shim rather than try to consume `deps/ghostty`'s NIF directly.

**`mob.add_nif --type zigler` pins a zig-0.16 Zigler fork** (`{:zigler, github:
"GenericJam/zigler", branch: "zig-016-port", override: true}`). Two reasons (both
per the scaffold's own moduledoc): macOS 26's SDK rejects symbols `compiler_rt`
references under **Zig 0.15.x**, and Zig 0.16's bare `nif_init` symbol collided
with Rustler's at static-link time. The `override: true` is required — `ghostty_ex`
declares `zigler ~> 0.15.2` and `zigler_precompiled` declares `~> 0.13`; we never
use `ghostty_ex`'s zig compilation (only its prebuilt host NIF), so overriding to
mob's fork is safe.

So: vendor a thin project Zigler NIF that calls `libghostty-vt`'s
`ghostty_terminal_*` C API (the VT half only), and link a **cross-built
`libghostty-vt.a`** for the target.

## 4. Per-platform status (Android proven; iOS gated on a macOS build host)

### The build-host wall (new, and it reorders the plan)
`libghostty-vt` is built by **upstream `ghostty-org/ghostty`'s `build.zig`**, which
hard-requires **zig 0.15.2** (its `requireZig` accepts only `0.15.x ≥ .2`; rejects
0.16, and the build.zig uses the 0.15 `readFileAlloc` API). **zig 0.15.2 cannot
link a native binary on this dev Mac (macOS 27.0 beta / Darwin 27)** — even a
hello-world fails with `__availability_version_check` + all of libSystem
undefined; older SDKs don't help; and the only zig that links here (0.16.0) is
rejected by ghostty. **No version manager (mise, etc.) resolves this** — 0.15.2 is
the only release satisfying ghostty, and it's the one that fails on macOS 27. So
`libghostty-vt` **must be built off this host.** (This is *only* about building
libghostty-vt; mob's own NIF compile uses the zig-0.16 fork and works here.)

### Android — PROVEN
- `libghostty-vt.a` for **`aarch64-linux-android`** is **built** on the Linux
  devbox (mise-pinned zig 0.15.2, which links cleanly there), 14.6 MB, exports
  `ghostty_terminal_*`. Artifact pulled to `native/ghostty_vt/lib-android-arm64/`;
  headers (`ghostty/vt.h` + `vt/*.h`, 30 files) to `native/ghostty_vt/include/`.
- **The bionic gap did NOT bite.** The `__tls_get_addr` / 16 KB-page wall
  (`ziglang/zig#23906`, ghostty #10902) hit Ghostty's *dynamic* `.so`; the
  libc-free **static** `.a` built clean. The NDK (r27c) was needed only because a
  build-dep (`simdutf`) requires it — not for libghostty-vt's own (libc-free) code.
- mob's project-zig path + Android's dynamic-`.so` tolerance make this the easy
  target. Remaining is mob wiring (§5), not a libghostty-vt question.

### iOS — feasible, deferred to a macOS build host
- libghostty-vt on iOS is a **shipping, solved** path, and ghostty's `build.zig`
  has first-class Apple support: `GhosttyLibVt.zig` enumerates
  `ApplePlatform { macos_universal, ios, ios_simulator }` and emits a
  `libghostty-vt.xcframework` (iOS device + sim slices) via
  `zig build -Demit-lib-vt -Demit-xcframework`.
- **But** the xcframework build needs macOS + `xcodebuild` AND zig 0.15.2 — which
  can't run on this Mac (above). So iOS is gated on a **macOS build host where zig
  0.15.2 works** (a `macos-15` CI runner — ghostty's own CI environment — or an
  older Mac). Local iOS toolchain is otherwise ready (Xcode 27 + iOS SDK 27 after
  the `xcode-select` fix).

## 5. Plan (Android first — forced by the host wall; the screen is the seam)

Decision: **Option A — android-only NIF now; keep `ghostty_ex`'s prebuilt NIF for
host-dev.** Rationale: we have the Android `libghostty-vt.a` (from ghostty *main*)
+ matching *main* headers, but **cannot build a matching macOS `libghostty-vt` on
this Mac** (the host wall), so a uniform host+device NIF must wait for the iOS/
macOS-host phase. The `TerminalScreen` branches on backend: `ghostty_ex`'s
`Ghostty.Terminal` (prebuilt, already works on the Mac host) for host-dev;
`CaseinMob.Nifs.GhosttyVt` (our project NIF + Android `.a`) on-device.

1. ✅ Build `libghostty-vt.a` for `aarch64-linux-android` (off-host, devbox).
2. ✅ `mix mob.add_nif ghostty_vt --type zigler` — stub at
   `lib/casein_mob/nifs/ghostty_vt.ex`; `static_nifs` entry; zigler-fork +
   `override: true`; deps resolved.
3. ⏳ Fill the Zig surface — adapt ghostty's `ghostty_nif.zig` **Terminal half**
   (`nif_new`, `nif_vt_write`, `nif_render_cells`, `nif_resize`, `nif_get_cursor`,
   `nif_snapshot`; **drop** the `nif_tty_*` / `termios` PTY half). Configure
   `use Zig` with `c: [include_dirs: [native/ghostty_vt/include], link_lib:
   <android .a>]`; set `static_nifs` to `archs: [:android]`.
4. ⏳ `CaseinMob.GhosttyVt` Elixir wrapper over the NIF; `TerminalScreen` calls it
   on-device (host keeps `ghostty_ex`), fed bytes **streamed from a host terminal**
   (Model-B-over-the-wire) instead of an on-device PTY.
5. ⏳ Rebuild + redeploy to SM-T577U; verify `cells/1` populates on-device (the
   `unknown application: :ghostty` crash should be gone).
6. ⏳ **iOS phase** (separate): build the `libghostty-vt.xcframework` on a macOS-15
   host, add `archs: [:ios]`, deploy to TestPad.

## 6. Open risks / unknowns

- **FIXED — Zigler-fork external-`.a` link under zig 0.16.** The fork
  (`zigler 0.16.0-mob1`) emitted `lib.addObjectFile(...)` in its generated
  `build.zig`, but zig 0.16 moved `addObjectFile`/`linkSystemLibrary`/
  `addCSourceFiles` off `Build.Step.Compile` onto `Build.Module`. Patched
  `render_c` (`lib/zig/_module.ex`) to route through `mode.root_module.*`; lives in
  `scratch/zigler-fork`, wired via the `path:` override in `native/casein_mob/mix.exs`.
  **Proven** with a trivial macOS `.a` (Zigler's `local_lib_test` pattern — link a
  local `.a`, call a function → returned 42). Zigler's own `local_lib`/`priv_lib`/
  `system_lib` cxx tests are Linux-only (need `libblas.so`); run them on the devbox
  for full coverage. **Durable fix = PR to `GenericJam/zigler#zig-016-port`** — do
  not leave it as the local path override.
- **CONFIRMED (now the gating blocker) — host vs. device.** `mix compile` builds
  this NIF for the macOS host, which can't link the Android `.a` (arch mismatch).
  Per Option A the host uses `ghostty_ex` and this NIF must compile **device-only**
  — mechanism not yet established; a matching macOS `libghostty-vt` can't be built
  on this macOS-27 box regardless. Converges with iOS on needing a **macOS-15
  build host**. *(With the generator bug ruled out, this is confirmed to be real
  target/arch work, not tooling.)*
- **Host↔device transport.** Streaming `cells`/PTY bytes over Mob distribution is
  unbuilt; until then the on-device terminal has no data source even with the NIF
  working.
- **`Canvas` painter.** Actually *drawing* the grid needs a `Canvas` node handler
  in `MobBridge.kt` (Android) / `.swift` (iOS) — a **separate gate** from the NIF.
- **iOS build host.** No `macos-15` runner/older Mac is set up yet.

## 7. What is verified vs. planned

- **Verified:** host pipeline; APK build + install + BEAM boot on Android device;
  Mob screens run on-device; the exact on-device crash + cause; the per-platform
  NIF-build mechanics (file-cited); libghostty-vt portability + iOS production
  precedent; **the macOS-27/zig-0.15.2 build-host wall**; **`libghostty-vt.a` built
  for `aarch64-linux-android`** (bionic gap a non-issue for the static lib); the
  zigler-fork dep resolution (`override: true`); project NIF scaffolded.
- **Also verified since the gate (the full on-device terminal works):**
  - `nif_render_cells` on-device — the earlier `:badarg` was an RPC
    resource-association artifact, not a bug (`{24, 10, true}` run on-device).
  - `CaseinMob.Terminal` backend abstraction — ghostty_ex on host, the NIF
    on-device; both yield `[[{grapheme, fg, bg, flags}]]`. `TerminalScreen`
    rewired to it; verified on-device (`backend=:nif`, banner → 49 Canvas ops).
  - **`MobBridge.kt` Canvas painter** already drew `rect`/`text`; added monospace
    `family` support so the grid is fixed-width.
  - **Host↔device transport (`CaseinMob.HostBridge`)** — a host shell's PTY bytes
    stream to the device's `:mob_screen` as `{:vt_bytes, _}`; **proven end-to-end**
    (host `echo` rendered in the on-device terminal, live, with the real prompt).
  - **Device → host input** — `HostBridge` announces itself (`{:vt_host, pid}`)
    to the device's `:mob_screen`; raw text, Enter, and key-bar bytes forward
    there (no local echo — the PTY line discipline owns echo/canonical mode).
    Verified on-device: `echo` renders once (no double-echo), `cd`/`pwd` shows
    shell state persists, Ctrl-C interrupts a running command. The terminal is
    now an interactive shell.
  - **Resize — done for Android.** The terminal measures a placed parent `Box`
    (not the Canvas), sends `{:change, :term_size, "WxH"}`, clamps to sane grid
    bounds, resizes the on-device Ghostty terminal, and sends `{:vt_resize, cols,
    rows}` to the host bridge so the PTY follows. Verified on SM-T577U arm64:
    device assigns `cols=63`, `rows=25`; host shell `stty size` returned `25 63`.
    The earlier Canvas measurement path remains unused because Canvas placement
    did not reliably fire `onGloballyPositioned`.
  - **Raw input + key bar — done.** The TextField now runs in `raw_input` mode:
    it stays visually empty and emits typed text immediately through
    `{:change, :input, bytes}`; Enter uses `on_submit`/button to send `\n` without
    closing the keyboard. The key bar sends raw bytes through the same
    `{:vt_input, _}` path (`Ctrl-C`=`<<3>>`, `Ctrl-D`=`<<4>>`, `Esc`=`<<27>>`,
    `Tab`=`"\t"`, Backspace=`<<127>>`, arrows=ANSI `\e[A..D`). No local echo.
    Verified on-device through the UI-equivalent message path: raw input rendered
    `RAW_OK`; Backspace corrected `echo RAQ` to `echo RAW_OK`; `Ctrl-C`
    interrupted `sleep 5`, after which `echo INTR_OK` ran immediately.
- **Planned / unproven:** the iOS `libghostty-vt.xcframework` build (needs a
  macOS-15 host) and iOS deploy.

## 8. The exact upstream PRs (deps are forked locally — not reproducible until these land)

Two forked dependency branches currently make `native/casein_mob` build; the
checkout is pinned to GitHub URLs in `mix.exs`/`mix.lock`, but should converge
back to upstream releases once the PRs land. Project-owned Android build edits
still live in the untracked `native/` tree until that app work is committed.

### PR 1 — `GenericJam/zigler` (`zig-016-port`): Android static-NIF support
The fork had iOS static-NIF support but the **Android** path was never exercised;
five distinct zig-0.16/NDK gaps, each surfaced by exercising one more feature:
1. **`lib/zig/_module.ex` `render_c`** — `addObjectFile`/`linkSystemLibrary`/
   `addCSourceFiles` moved off `Build.Step.Compile` onto `Build.Module` in zig
   0.16; route through `mode.root_module.*`. (Blocks any external `link_lib`.)
2. **`priv/beam/get.zig`** — `std.meta.intToEnum` (error union) → `std.enums.fromInt`
   (`?E`). (Blocks Resource-using NIFs.)
3. **`lib/zig/templates/build_mod.zig.eex`** — add an `android_sdkroot` option +
   NDK `usr/include` (+ arch-triple) include paths, mirroring `apple_sdkroot`.
   (Blocks cross-compile: erl_nif.h's cImport needs NDK headers.)
4. **`priv/beam/erl_nif.zig`** — `@cDefine` `_Nullable`/`_Nonnull`/
   `_Null_unspecified` to `""` before `@cInclude("erl_nif.h")`; bionic annotates
   array params with `_Nullable`, which zig 0.16 translate-c rejects.
5. **`lib/zig/templates/build_mod.zig.eex`** — set `module.pic = true` on the NIF
   modules when `nif_linkage == .static`; a static NIF links into a `-shared`
   binary, so local-exec TLS relocations (`beam.context` `R_AARCH64_TLSLE_*`) are
   otherwise rejected.

### PR 2 — `mob_dev`: `:static_nifs` `:extra_static_libs`
Lets a project NIF resolve `extern` symbols (e.g. a prebuilt `libghostty-vt.a`)
at the **app** link without host-linking an arch-mismatched archive:
1. **`lib/mob_dev/static_nifs.ex`** — validate `:extra_static_libs` (non-empty map
   of concrete arch → path).
2. **`lib/mob_dev/native_build.ex` `project_nif_zig_args/1`** — append matching
   per-arch archives into the `project_rust_libs` lane (after the NIF archives, so
   link order resolves the NIF's undefined symbols); emit `-D<module>_static=true`
   for guarded on-platform entries.
3. **mob_new project `build.zig` template** — declare each `<module>_static`
   build option and add it to the driver_tab `build_options` (the generated
   `driver_tab_android.zig` gates rows on `build_options.<module>_static`). The
   spike hardcodes `ghostty_vt_static`; the durable version derives it from the
   `:static_nifs` entries.

### Approach pattern (for the design, not for upstreaming)
NIF declares `extern ghostty_terminal_*` and **host-links nothing** (undefined
symbols are fine in the host `.so`, like `enif_*`); the per-arch `libghostty-vt.a`
is static-linked into the app binary via `:extra_static_libs`; a `:guard` +
`archs: [:android_arm64]` gate it to the one ABI we have an archive for.
