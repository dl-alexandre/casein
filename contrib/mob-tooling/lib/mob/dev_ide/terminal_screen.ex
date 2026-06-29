defmodule Mob.DevIde.TerminalScreen do
  @moduledoc """
  Native Mob terminal slice — a real `Ghostty.Terminal` rendered as a styled
  monospace grid via Mob's `Canvas`. This is the on-device equivalent of
  dev_ide's web Ghostty terminal: **Model B** (ghostty owns the VT state machine
  and grid; the view renders `cells/1`), the architecture verified in
  `docs/subsystems/ghostty_terminal_contract.md`.

  > **STAGED, NOT COMPILED HERE.** This file lives under `contrib/` (outside
  > dev_ide's `elixirc_paths`) so it never reaches dev_ide's `mix compile`. It is
  > written against real, source-verified APIs but **must be copied into a Mob
  > project to run** — see "Where this runs" below.

  ## What it does (the real-terminal wiring)

  On `mount/3` it starts a genuine terminal:

      {:ok, term} = Ghostty.Terminal.start_link(cols: 80, rows: 24)
      {:ok, pty}  = Ghostty.PTY.start_link(cmd: shell(), cols: 80, rows: 24)

  `Ghostty.PTY` sends the child shell's output to its **owner process** (this
  screen's GenServer) as `{:data, binary}` messages — there is no auto-wire. So
  the data pump is explicit (`pty.ex` moduledoc, ghostty 0.4.9):

      handle_info({:data, bytes}) -> Ghostty.Terminal.write(term, bytes) -> repaint

  Each repaint reads the live grid with `Ghostty.Terminal.cells/1 ::
  [[Cell.t()]]` and draws it. Bursty output (e.g. `cat bigfile`) is **coalesced**
  to one repaint per frame (`@repaint_ms`) rather than one per `{:data, ...}`,
  matching the perf guidance in the terminal contract (§5).

  ## Cell → Canvas mapping

  A cell is the verified 4-tuple `{grapheme, fg, bg, flags}`. We use the
  `Ghostty.Terminal.Cell` accessors rather than decoding `flags` by hand:

  | ghostty (verified) | Mob Canvas |
  |---|---|
  | `Cell.bg/1` (`color \\| nil`) | `Mob.Canvas.rect/5` fill behind the cell |
  | `Cell.grapheme/1` (binary) | `Mob.Canvas.text/4` at `{col*cellw, row*cellh}` |
  | `Cell.fg/1` (`color \\| nil`) | `text color:` |
  | `Cell.bold?/1` | `text weight: :bold` |
  | `Ghostty.Terminal.cursor/1` | inverse-block `rect` overlay |

  **Color bridge:** ghostty colors are RGB; Mob color props are usually named
  atoms — but `Mob.Renderer.resolve_color/2` passes a **raw integer through
  unchanged**, so we convert ghostty RGB to a `0xAARRGGBB` int and hand it
  straight to Mob. `nil` falls back to theme atoms (`:on_surface` / `:background`).

  **Known limitation (this Mob version):** Mob text supports color + size +
  weight, but **not italic/underline/strikethrough**. Those ghostty flags are
  dropped here; revisit if/when Mob adds run attributes. Bold maps to weight.

  ## Where this runs (the integration venue — read before "it doesn't compile")

  No project on the box today has **both** `mob` and `ghostty` deps. To run this:

  1. Drop this module into a Mob app (e.g. the `meshx` umbrella's `mob_node`, or
     a fresh `mix mob.new` project).
  2. Add `{:ghostty, "~> 0.4"}` to that app's deps.
  3. Register it as the root screen: `Mob.Screen.start_root(Mob.DevIde.TerminalScreen)`.

  **Host first, device as a gate.** `ghostty` is a Zig **NIF**. It builds for the
  host (macOS/Linux), so you can verify the renderer headlessly today:

      {:ok, pid} = Mob.Screen.start_link(Mob.DevIde.TerminalScreen, %{})
      # drive the shell, then assert the grid tree built from real cells/1:
      Mob.Test.assigns(node).draw   # => list of Mob.Canvas ops
      Mob.Test.tree(node)           # => full render tree

  Running it **on an attached device** requires the ghostty NIF cross-compiled
  for iOS/Android arm64 — the one piece both the contract doc (§7) and
  `TERMINAL-INTEGRATION-SKETCH.md` (§6 Q7) fence as *unverified*. If that cross-
  compile lands, this is a fully native on-device terminal. If it can't, the
  fallback is identical screen code fed by a **host-held** `Ghostty.Terminal`
  streaming `cells/1` frames over Mob distribution (dev_ide's existing
  Model-B-over-the-wire) — `cells/1` is the seam either way.
  """

  use Mob.Screen

  import Bitwise

  alias Ghostty.Terminal
  alias Ghostty.Terminal.Cell
  alias Ghostty.PTY

  # Fixed monospace cell metrics (logical units; renderer scales to device px).
  @cellw 9
  @cellh 18
  @cols 80
  @rows 24

  # Coalesce bursty PTY output to ~60fps instead of one repaint per {:data, _}.
  @repaint_ms 16

  # Default foreground when a cell reports `nil` fg (theme atom — Mob resolves
  # it; a raw int would work too). A `nil` bg draws no rect, so the Column's
  # `:background` shows through as the terminal's default background.
  @default_fg :on_surface
  @cursor_color 0xFFE0E0E0

  @impl true
  def mount(_params, _session, socket) do
    {:ok, term} = Terminal.start_link(cols: @cols, rows: @rows)
    {:ok, pty} = PTY.start_link(cmd: shell(), cols: @cols, rows: @rows)

    socket =
      socket
      |> Mob.Socket.assign(:term, term)
      |> Mob.Socket.assign(:pty, pty)
      |> Mob.Socket.assign(:cols, @cols)
      |> Mob.Socket.assign(:rows, @rows)
      |> Mob.Socket.assign(:input, "")
      |> Mob.Socket.assign(:closed?, false)
      |> Mob.Socket.assign(:repaint_scheduled?, false)
      |> Mob.Socket.assign(:draw, [])

    {:ok, repaint(socket)}
  end

  # ── PTY → Terminal data pump ────────────────────────────────────────────────

  @impl true
  def handle_info({:data, bytes}, socket) when is_binary(bytes) do
    Terminal.write(socket.assigns.term, bytes)
    {:noreply, ensure_repaint(socket)}
  end

  def handle_info({:exit, status}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:closed?, true)
     |> Mob.Socket.assign(:exit_status, status)}
  end

  # Coalesced repaint tick.
  def handle_info(:repaint, socket) do
    socket = Mob.Socket.assign(socket, :repaint_scheduled?, false)
    {:noreply, repaint(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ── Input (minimal first slice: line-buffered send) ─────────────────────────
  #
  # Mob's TextField surfaces `on_change` with the full value; a terminal really
  # wants per-keystroke bytes (and a key bar for Ctrl/Esc/arrows — sketch §3).
  # For this slice we line-buffer: type into the field, "Send" writes the line +
  # newline to the PTY. Richer key encoding via `Terminal.input_key/2` is the
  # next step.

  @impl true
  def handle_event("input_change", %{"value" => value}, socket) do
    {:noreply, Mob.Socket.assign(socket, :input, value)}
  end

  def handle_event("send", _params, socket) do
    PTY.write(socket.assigns.pty, socket.assigns.input <> "\n")
    {:noreply, Mob.Socket.assign(socket, :input, "")}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~MOB"""
    <Column background={:background} padding={:space_md} gap={:space_sm} fill_width={true}>
      <Text text="MobNode terminal (ghostty cells/1)" text_size={:lg} text_color={:on_surface} />
      <Canvas width={@cols * @cellw} height={@rows * @cellh} draw={@draw} />
      <Row gap={:space_sm} fill_width={true}>
        <TextField
          id={:term_input}
          value={@input}
          on_change={{self(), :input_change}}
          return_key="send"
          weight={1}
        />
        <Button text="Send" on_tap={{self(), :send}} />
      </Row>
    </Column>
    """
  end

  # ── Grid → Canvas ops ───────────────────────────────────────────────────────

  defp repaint(socket) do
    %{term: term} = socket.assigns
    grid = Terminal.cells(term)
    {cur_col, cur_row} = Terminal.cursor(term)

    ops =
      grid
      |> Enum.with_index()
      |> Enum.flat_map(fn {row, r} -> row_ops(row, r) end)

    ops = ops ++ [cursor_op(cur_col, cur_row)]

    Mob.Socket.assign(socket, :draw, ops)
  end

  defp row_ops(row, r) do
    row
    |> Enum.with_index()
    |> Enum.flat_map(fn {cell, c} -> cell_ops(cell, r, c) end)
  end

  defp cell_ops(cell, r, c) do
    if Cell.blank?(cell) do
      []
    else
      x = c * @cellw
      y = r * @cellh
      grapheme = Cell.grapheme(cell)

      bg_ops =
        case Cell.bg(cell) do
          nil -> []
          bg -> [Mob.Canvas.rect(x, y, @cellw, @cellh, color: argb(bg), fill: true)]
        end

      text_op =
        Mob.Canvas.text(x, y, grapheme,
          color: argb(Cell.fg(cell)) || @default_fg,
          weight: if(Cell.bold?(cell), do: :bold, else: :regular),
          family: "Menlo"
        )

      bg_ops ++ [text_op]
    end
  end

  # Inverse block cursor overlay (drawn last so it sits on top).
  defp cursor_op(col, row) do
    Mob.Canvas.rect(col * @cellw, row * @cellh, @cellw, @cellh,
      color: @cursor_color,
      fill: true
    )
  end

  # ── Color bridge: ghostty color -> 0xAARRGGBB int (Mob passes ints through) ──
  #
  # ghostty `Cell.fg/1`/`Cell.bg/1` return `color | nil`. The exact runtime shape
  # (integer `0xRRGGBB`, `{r, g, b}` tuple, or already-`0xAARRGGBB`) is handled
  # defensively below. VERIFY against deps/ghostty/lib/ghostty/terminal/cell.ex
  # when the dep is local and tighten this if the shape is known.
  defp argb(nil), do: nil
  defp argb({r, g, b}), do: 0xFF000000 ||| r <<< 16 ||| g <<< 8 ||| b

  defp argb(int) when is_integer(int) do
    # If alpha already present (top byte set) keep it; else force opaque.
    if int > 0xFFFFFF, do: int, else: 0xFF000000 ||| int
  end

  defp argb(other), do: other

  defp ensure_repaint(%{assigns: %{repaint_scheduled?: true}} = socket), do: socket

  defp ensure_repaint(socket) do
    Process.send_after(self(), :repaint, @repaint_ms)
    Mob.Socket.assign(socket, :repaint_scheduled?, true)
  end

  defp shell, do: System.get_env("SHELL") || "/bin/sh"
end
