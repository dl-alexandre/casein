# Ghostty terminal contract (verified) — and what it means for native

> **Provenance:** every contract below is read from source **in this repo** —
> the `ghostty` hex dep (`~> 0.4`, locked **0.4.9**, `mix.exs:88` / `mix.lock:41`)
> and dev_ide's own terminal adapters. File:line citations are given so it can
> be re-checked. This **supersedes the `# ASSUMPTION` parts** of
> `contrib/mob-tooling/TERMINAL-INTEGRATION-SKETCH.md` that concern the terminal
> grid/PTY — those are no longer speculative.
>
> **Still NOT verified here** (no source on this machine): the Mob `mix mob.*`
> device task surface, and any **native iOS/Android renderer** — dev_ide renders
> the grid in a browser today (§5). Those remain explicitly fenced in §7.

## 1. The dependency is real and native

`ghostty` 0.4.9 is a NIF-backed terminal emulator (Zig via `zigler` /
`zigler_precompiled`, `mix.lock:41`). `cringe` and `ttycast` also depend on it
(`mix.lock:16,97`). The backend type is decided by the dep, not by us:
`Ghostty.TTY.Backend` carries `type: :nif` (`deps/ghostty/lib/ghostty/tty/backend.ex:25`),
and there are `Ghostty.Terminal.Nif` / `Ghostty.PTY.Nif` modules. **§6 Q6 is
answered by the dep: it's a NIF.**

## 2. `Ghostty.Terminal` — the verified contract

From `deps/ghostty/lib/ghostty/terminal.ex`:

| Function | Spec | Notes |
|---|---|---|
| `start_link/1` | `[option()] :: GenServer.on_start()` | :112 |
| `write/2` | `(server, iodata()) :: :ok` | :144 — **`GenServer.call`**, not cast |
| `resize/3` | `(server, pos_integer(), pos_integer()) :: :ok` | :160 — confirm arg order vs impl |
| `reset/1` | `:ok` | :170 |
| `snapshot/2` | `(server, format()) :: {:ok, binary()}` | :191, `format \\ :plain`, formats `:html | :plain | :vt` |
| `cells/1` | `(server) :: [[cell()]]` | :215 — **the raw grid** |
| `input_key/2` | `(server, Ghostty.KeyEvent.t()) :: {:ok, binary()} | :none` | :235 — **encodes key→bytes** |
| `input_mouse/2` | `(server, Ghostty.MouseEvent.t()) :: {:ok, binary()} | :none` | :246 — **encodes mouse/touch→bytes** |
| `encode_focus/1` | `(boolean()) :: {:ok, binary()} | :none` | :260 |
| `scrollbar/1` | `:: scrollbar()` | :268 |
| `scroll/2` | `(server, integer()) :: :ok` | :287 — **scrollback scroll** |
| `cursor/1` | `:: {non_neg_integer(), non_neg_integer()}` | :295 |
| `size/1` | `:: {pos_integer(), pos_integer()}` | :303 |
| `cursor_state/1`, `render_state/1`, `mouse_modes/1` | | :311/:321/:331 |

`Ghostty.PTY` (`deps/ghostty/lib/ghostty/pty.ex`) mirrors this for the PTY:
`start_link/1`, `write/2` (:80), **`resize(server, cols, rows)`** (:86–87 — order
is **cols, rows**), `close/1` (:97). `Ghostty.TTY.write/2` is `GenServer.call`
(:70–71).

### Cell shape (corrects the sketch's Q2)

`Ghostty.Terminal.Cell` (`deps/ghostty/lib/ghostty/terminal/cell.ex`) — a cell is
the 4-tuple **`{grapheme, fg, bg, flags}`**:

```elixir
grapheme({char, _, _, _})        # :40 — binary, the glyph cluster
fg({_, fg, _, _})                # :44 — color | nil
bg({_, _, bg, _})                # :48 — color | nil
flags({_, _, _, flags})          # :52 — bitmask
# bold? italic? faint? underline? strikethrough? inverse? blink? overline?  (:55–:77)
blank?({char, fg, bg, flags})    # :80 — "" and nil fg/bg and flags == 0
```

So vs. the draft's proposed `%{cells: [{row, col, codepoints, fg, bg, attrs, width}]}`:

- **No `row`/`col`** — position is the index in `[[cell()]]` (`cells/1`).
- **No `width` field** — wide glyphs are carried in `grapheme` plus a trailing
  `blank?` cell; honor the grid layout, don't measure width yourself.
- **`snapshot/2` ≠ the grid** — it returns a *rendered* `:html | :plain | :vt`
  binary (used for artifacts/preview), while `cells/1` is the live grid.
- **No `dirty_regions` in the API** — 0.4.9 returns the full grid; incremental
  rendering is an **app-level diff** (see §3), not a ghostty feature.

## 3. How dev_ide renders today: Model B, in the browser

`Ghostty.Terminal.cells/1` gives the grid as data and dev_ide renders it
client-side — i.e. **§6 Q1 = Model B, already shipped** (for web):

- `lib/dev_ide_web/components/ghostty_terminal_component.ex` mounts a JS hook
  `phx-hook="GhosttyTerminal"` with `phx-update="ignore"` (:51–52) and pushes
  frames with `Phoenix.LiveView.push_event(socket, "ghostty:render", payload)`
  (:212). Input is captured via a hidden `<textarea data-ghostty-input>` (:60).
- **Incremental frames are an app-level diff:** the component threads
  `previous_cells` → `last_render_cells` (:25, :206–:211) and only encodes
  what changed. That's the answer to "dirty regions" — dev_ide computes them; the
  dep does not expose them.

A native iOS/Android view would consume the **same `cells/1` contract**, but the
renderer itself (SwiftUI/Compose/Metal) is **not in this repo** — see §7.

## 4. Input: use ghostty's encoders, not hand-rolled escapes (corrects §3 of the sketch)

The sketch proposed mapping gestures to ANSI sequences by hand. The dep already
does this correctly:

- **Keys:** build a `Ghostty.KeyEvent`, call `input_key/2` → `{:ok, bytes}` →
  write to the PTY. `Ghostty.KeyDecoder.decode/1` exists for the reverse.
- **Touch/mouse:** build a `Ghostty.MouseEvent`, call `input_mouse/2` →
  `{:ok, bytes}`. This respects the app's mouse mode (`mouse_modes/1`), so a
  tap/drag becomes the *right* sequence for `vim`/`less` vs. a raw shell.
- **Focus:** `encode_focus/1` for focus-reporting apps; gate on
  `focus_reporting?/1`.

Net: the gesture layer's job is to construct `KeyEvent`/`MouseEvent` and let
ghostty encode — not to emit `\e[A` etc. directly.

## 5. Ownership & lifecycle (verified — corrects §5/§8 of the sketch)

Production terminals are **tmux-backed**, not direct `Ghostty.PTY`:

- `DevIDE.Terminals.Session` is the canonical PTY owner, keyed by
  `{workspace, sid}` (`lib/dev_ide/terminals/ghostty_raw_adapter.ex:6–14,29–43`),
  supervised under `SessionOwner` (`session_owner.ex`, ~951 LoC).
- `GhosttyRawAdapter` bridges raw channel joins (`terminal:<ws>:<sid>`) onto the
  same `SessionOwner` so a raw join and a LiveView pane share one PTY + one
  attachment — no extra `Ghostty.PTY` client (`ghostty_raw_adapter.ex:9–18`).
- The direct `:ghostty_pty` backend (one `Ghostty.PTY`/`Ghostty.Terminal`
  GenServer per pane) is **legacy, retained for tests/rollback**, not the prod
  default (`ghostty_raw_adapter.ex:16–18`).

**Scrollback (§6 Q8):** ghostty owns viewport scrollback natively — `scroll/2`
and `scrollbar/1` — *and* there's a tmux history layer underneath. So scrollback
is **not** a hand-rolled BEAM buffer as the sketch assumed; a scroll gesture
drives `Ghostty.Terminal.scroll/2` (or tmux copy-mode), and must not write to the
PTY.

**Resize (§6 Q4):** `Ghostty.PTY.resize(server, cols, rows)` / `Terminal.resize/3`
— call it from the session owner on pinch/rotate/keyboard, debounced to the final
size. We do **not** poke `TIOCSWINSZ` ourselves; the dep does.

## 6. Resolved §6, in one line each

1. **Render boundary:** Model B, *already shipped for web* via `cells/1`.
2. **Grid API:** `cells/1 :: [[{grapheme, fg, bg, flags}]]`; `snapshot/2` is a
   rendered `:html/:plain/:vt` artifact; dirty-diff is app-level.
3. **Input/write:** `write/2` (call, iodata) for raw bytes; prefer
   `input_key/2` + `input_mouse/2` to encode events.
4. **Resize:** `PTY.resize(server, cols, rows)` / `Terminal.resize/3`, from the
   session owner, debounced.
5. **Lifecycle:** tmux-backed `Terminals.Session` per `{workspace, sid}` under
   `SessionOwner`; direct `Ghostty.PTY` is legacy/test.
6. **NIF vs port:** NIF, fixed by the dep.
7. **Mobile renderer:** *unverified* — see §7.
8. **Scrollback:** ghostty (`scroll/2`/`scrollbar/1`) + tmux history; not a
   BEAM-side buffer.

## 7. The fence: what is still genuinely unverified

Do **not** treat these as settled — there is no source for them on this machine:

- **Mob device task surface.** `mix mob.dev`, `mix mob.ping`, `mix mob.connect`,
  and `Mob.Device.subscribe/1`'s event shape remain `# ASSUMED MOB API` in
  `contrib/mob-tooling/`. This doc does **not** rename them to "real" tasks,
  because the Mob repo isn't here to confirm them.
- **Native iOS/Android renderer.** dev_ide renders the grid in a browser (§3).
  A SwiftUI/Compose/Metal renderer that consumes `cells/1` is a *design target*,
  not existing code. The **contract it would consume is verified**; the renderer
  is not built.

When the Mob checkout and a native shell land on the box, the §7 items get the
same source-verified treatment as §2–§5, and the `# ASSUMED MOB API` tags get
replaced with real signatures — not before.
