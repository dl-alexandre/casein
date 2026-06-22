defmodule DevideMob.Nifs.GhosttyVt do
  @moduledoc """
  Project-local Zigler NIF wrapping `libghostty-vt`'s VT engine — the **Terminal
  half** of ghostty's NIF (`cells/1`, `vt_write`, `resize`, `cursor`), with **no
  PTY/`forkpty`** (that runs host-side; the device is fed host-streamed bytes).
  See `docs/subsystems/mob_ondevice_terminal_gate.md`.

  ## Staged, NOT yet wired — one blocker left (recorded in the gate doc §6)

  The real Zig surface is vendored at `ghostty_vt_nif.zig` (this dir), the C
  headers at `native/ghostty_vt/include/`, and the cross-built Android archive at
  `native/ghostty_vt/lib-android-arm64/libghostty-vt.a`.

  1. ✅ **Zigler-fork external-`.a` link bug — FIXED.** The fork emitted
     `lib.addObjectFile(...)` (a method zig 0.16 moved off `Build.Step.Compile`
     onto the module). Patched in `render_c` to route through `lib.root_module`
     (`scratch/zigler-fork`, via the `path:` override in `mix.exs`); proven with a
     trivial macOS `.a` (`local_lib_test` pattern). Durable fix = a PR to
     `GenericJam/zigler#zig-016-port`.
  2. ⏳ **Host vs. device.** `mix compile` builds this NIF for the **macOS host**,
     which can't link the **Android** `.a`. Per Option A the host uses
     `ghostty_ex`'s prebuilt `Ghostty.Terminal`; this NIF should compile
     **device-only** — mechanism not yet established (and a matching macOS
     `libghostty-vt` can't be built on this macOS-27 box anyway).

  Until (2) is resolved this module stays an inert stub so the project keeps
  compiling for host-dev. The intended config was:

      use Zig, otp_app: :devide_mob,
        zig_code_path: "ghostty_vt_nif.zig",
        c: [include_dirs: [".../native/ghostty_vt/include"],
            link_lib: ".../native/ghostty_vt/lib-android-arm64/libghostty-vt.a"]
  """

  # No `link_lib`: the `ghostty_terminal_*` symbols stay *undefined* in the host
  # `.so` (like `enif_*`), so host `mix compile` succeeds without an arch-matched
  # libghostty-vt. They resolve on-device when mob static-links the per-arch
  # `libghostty-vt.a` into the app binary (mob.exs `:extra_static_libs`).
  @ghostty_vt Path.expand("../../../native/ghostty_vt", __DIR__)

  use Zig,
    otp_app: :devide_mob,
    zig_code_path: "ghostty_vt_nif.zig",
    resources: [:TerminalResource],
    c: [include_dirs: [Path.join(@ghostty_vt, "include")]]
end
