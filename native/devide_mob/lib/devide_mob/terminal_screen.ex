defmodule DevideMob.TerminalScreen do
  @moduledoc """
  On-device terminal — a real VT engine rendered as a monospace `Canvas` grid.

  The Mob equivalent of dev_ide's web Ghostty terminal: **Model B** — the VT
  engine owns the state machine + grid; this screen renders `cells/1`. The
  terminal backend is abstracted by `DevideMob.Terminal`: `ghostty_ex` on the
  host (dev), the static `DevideMob.Nifs.GhosttyVt` NIF on-device. Both yield the
  same `[[{grapheme, fg, bg, flags}]]` cell shape, so the renderer below is
  backend-agnostic.

  ## Byte source

  * **host (dev):** a local `Ghostty.PTY` runs a shell and streams `{:data, _}`.
  * **on-device:** no shell (sandbox); a host `DevideMob.HostBridge` streams
    `{:vt_bytes, _}` over Mob distribution (Model-B-over-the-wire) and is the input
    sink (raw TextField/key-bar bytes → `{:vt_input, _}` → its PTY). No local echo
    — the PTY decides it.

  Bursty output is coalesced to ~`@repaint_ms`/frame. ghostty colors are
  `{0..255,0..255,0..255} | nil`, packed to `0xAARRGGBB` ints (`Mob.Renderer`
  passes raw ints through). Bold maps to `weight: :bold`; italic/underline have no
  Mob text attribute and are dropped. `<Canvas>` is a host-app component — the
  `:draw` ops are painted by `MobBridge`.
  """

  use Mob.Screen

  import Bitwise

  alias DevideMob.Terminal

  # Per-cell size in **dp** (the Canvas draws in dp), so cols/rows derive from the
  # measured terminal slot: cols = floor(width_dp / @cellw).
  @cellw 9
  @cellh 18
  # Glyph point size — < @cellh so descenders/line-gap fit the cell box.
  @font_size 14
  # Grid dims start at a sane default and are recomputed from the measured terminal
  # slot. Clamped so tiny/transition layouts never resize the PTY to garbage.
  @default_cols 80
  @default_rows 24
  @min_cols 20
  @max_cols 400
  @min_rows 4
  @max_rows 200
  @repaint_ms 16

  @terminal_bg 0xFF080A0C
  @terminal_surface 0xFF101214
  @terminal_panel 0xFF171A1D
  @terminal_border 0xFF31363B
  @terminal_key_bg 0xFF24282D
  @terminal_key_fg 0xFFE7ECEF
  @default_fg 0xFFE7ECEF
  @cursor_color 0xFFE0E0E0

  def mount(_params, _session, socket) do
    term = Terminal.new(@default_cols, @default_rows)

    pty =
      if Terminal.host?() do
        {:ok, pty} =
          Ghostty.PTY.start_link(cmd: shell(), cols: @default_cols, rows: @default_rows)

        pty
      else
        # On-device: no PTY and no local echo — the host's PTY is the only source
        # of rendered bytes. Empty until a HostBridge connects and streams.
        nil
      end

    socket =
      socket
      |> Mob.Socket.assign(:term, term)
      |> Mob.Socket.assign(:pty, pty)
      # On-device, the host's DevideMob.HostBridge announces itself here so input
      # can flow back to the shell. nil until a host connects.
      |> Mob.Socket.assign(:vt_host, nil)
      |> Mob.Socket.assign(:cols, @default_cols)
      |> Mob.Socket.assign(:rows, @default_rows)
      |> Mob.Socket.assign(:repaint_scheduled?, false)
      |> Mob.Socket.assign(:draw, [])

    {:ok, repaint(socket)}
  end

  def render(assigns) do
    draw = assigns.draw
    canvas_w = assigns.cols * @cellw
    canvas_h = assigns.rows * @cellh

    ~MOB"""
    <Column background={@terminal_bg} fill_width={true} fill_height={true}>
      <Row background={:primary} padding={:space_sm} gap={8} fill_width={true}>
        <Button
          text="Back"
          height={44.0}
          background={:surface_raised}
          text_color={:on_surface}
          padding={:space_sm}
          on_tap={{self(), :back}}
        />
        <Text
          text="Terminal"
          text_size={:lg}
          text_color={:on_primary}
          font_weight="bold"
          weight={1}
        />
        <Text
          text={status_line(assigns)}
          text_size={:xs}
          text_color={@terminal_key_fg}
          background={status_badge_color(assigns)}
          padding_left={:space_sm}
          padding_right={:space_sm}
          padding_top={4}
          padding_bottom={4}
        />
      </Row>
      <Column
        background={@terminal_bg}
        padding={6}
        gap={6}
        fill_width={true}
        fill_height={true}
        weight={1}
      >
        <Text
          text={terminal_meta(assigns)}
          text_size={12.0}
          text_color={@terminal_key_fg}
          padding={4}
        />
        <Box
          id="terminal-surface"
          on_change={{self(), :term_size}}
          background={@terminal_surface}
          border_color={@terminal_border}
          border_width={1.0}
          corner_radius={6.0}
          padding={6}
          fill_width={true}
          fill_height={true}
          weight={1}
        >
          <Canvas width={canvas_w} height={canvas_h} draw={draw} />
          <TextField
            id="terminal-input"
            value=""
            keyboard={:default}
            return_key={:send}
            raw_input={true}
            terminal_capture={true}
            background={0x00000000}
            padding={0}
            corner_radius={0.0}
            keep_keyboard_on_submit={true}
            on_change={{self(), :input}}
            on_submit={{self(), :enter}}
            fill_width={true}
            fill_height={true}
          />
        </Box>
        <Column
          id="terminal-keybar"
          background={@terminal_panel}
          corner_radius={6.0}
          padding={4}
          gap={4}
          fill_width={true}
        >
          <Row gap={4} fill_width={true}>
            <Button
              text="Esc"
              compact={true}
              height={36.0}
              corner_radius={4.0}
              background={@terminal_key_bg}
              text_color={@terminal_key_fg}
              text_size={12.0}
              weight={1}
              on_tap={{self(), :esc}}
            />
            <Button
              text="Tab"
              compact={true}
              height={36.0}
              corner_radius={4.0}
              background={@terminal_key_bg}
              text_color={@terminal_key_fg}
              text_size={12.0}
              weight={1}
              on_tap={{self(), :tab}}
            />
            <Button
              text="^C"
              compact={true}
              height={36.0}
              corner_radius={4.0}
              background={@terminal_key_bg}
              text_color={@terminal_key_fg}
              text_size={12.0}
              weight={1}
              on_tap={{self(), :ctrl_c}}
            />
            <Button
              text="^D"
              compact={true}
              height={36.0}
              corner_radius={4.0}
              background={@terminal_key_bg}
              text_color={@terminal_key_fg}
              text_size={12.0}
              weight={1}
              on_tap={{self(), :ctrl_d}}
            />
          </Row>
          <Row gap={4} fill_width={true}>
            <Button
              text="←"
              compact={true}
              height={36.0}
              corner_radius={4.0}
              background={@terminal_key_bg}
              text_color={@terminal_key_fg}
              text_size={14.0}
              weight={1}
              on_tap={{self(), :left}}
            />
            <Button
              text="↑"
              compact={true}
              height={36.0}
              corner_radius={4.0}
              background={@terminal_key_bg}
              text_color={@terminal_key_fg}
              text_size={14.0}
              weight={1}
              on_tap={{self(), :up}}
            />
            <Button
              text="↓"
              compact={true}
              height={36.0}
              corner_radius={4.0}
              background={@terminal_key_bg}
              text_color={@terminal_key_fg}
              text_size={14.0}
              weight={1}
              on_tap={{self(), :down}}
            />
            <Button
              text="→"
              compact={true}
              height={36.0}
              corner_radius={4.0}
              background={@terminal_key_bg}
              text_color={@terminal_key_fg}
              text_size={14.0}
              weight={1}
              on_tap={{self(), :right}}
            />
            <Button
              text="⌫"
              compact={true}
              height={36.0}
              corner_radius={4.0}
              background={@terminal_key_bg}
              text_color={@terminal_key_fg}
              text_size={14.0}
              weight={1}
              on_tap={{self(), :backspace}}
            />
            <Button
              text="↵"
              compact={true}
              height={36.0}
              corner_radius={4.0}
              background={@terminal_key_bg}
              text_color={@terminal_key_fg}
              text_size={14.0}
              weight={1}
              on_tap={{self(), :enter}}
            />
          </Row>
        </Column>
      </Column>
    </Column>
    """
  end

  # ── Byte sources → terminal ──────────────────────────────────────────────────

  # host: local Ghostty.PTY shell output.
  def handle_info({:data, bytes}, socket) when is_binary(bytes) do
    Terminal.write(socket.assigns.term, bytes)
    {:noreply, ensure_repaint(socket)}
  end

  # device: bytes streamed from a host terminal over Mob distribution (Model-B).
  def handle_info({:vt_bytes, bytes}, socket) when is_binary(bytes) do
    Terminal.write(socket.assigns.term, bytes)
    {:noreply, ensure_repaint(socket)}
  end

  # device: the host bridge announcing itself as the input sink. Sync the host
  # PTY to our current grid so the two agree from the first byte.
  def handle_info({:vt_host, host}, socket) when is_pid(host) do
    send(host, {:vt_resize, socket.assigns.cols, socket.assigns.rows})
    {:noreply, Mob.Socket.assign(socket, :vt_host, host)}
  end

  # Resize path: given a measured terminal slot "WxH" (dp), recompute the grid to fit,
  # clamp, and resize the terminal + its byte source so the PTY and rendered grid
  # agree. The native Android bridge reports this from the parent Box rather than
  # the Canvas itself; Canvas placement was not reliable enough for measurement.
  def handle_info({:change, :term_size, wxh}, socket) when is_binary(wxh) do
    case parse_wxh(wxh) do
      {w, h} ->
        {:noreply, resize_to(socket, div(w, @cellw), div(h, @cellh))}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_info({:exit, _status}, socket), do: {:noreply, socket}

  def handle_info({:resize_terminal, cols, rows}, socket)
      when is_integer(cols) and is_integer(rows) do
    {:noreply, resize_to(socket, cols, rows)}
  end

  def handle_info(:repaint, socket) do
    {:noreply, socket |> Mob.Socket.assign(:repaint_scheduled?, false) |> repaint()}
  end

  # ── Mob UI events (0.7: tags deliver tuples to handle_info) ──────────────────

  def handle_info({:change, :input, value}, socket) do
    send_input(socket, value)
    {:noreply, socket}
  end

  # Terminals send carriage return for Enter. Shell canonical mode accepts this
  # and raw TUIs (Codex, vim, prompts) often require it.
  def handle_info({:tap, :enter}, socket), do: transmit(socket, "\r")
  def handle_info({:submit, :enter}, socket), do: transmit(socket, "\r")

  def handle_info({:tap, :back}, socket) do
    {:noreply, Mob.Socket.pop_screen(socket)}
  end

  # Key bar: send raw control/escape bytes through the same device→host path, no
  # local echo (the PTY decides). Arrows use the standard ANSI cursor sequences
  # (history / cursor / vi nav). DEL is the normal PTY erase byte for Backspace.
  @key_bytes %{
    ctrl_c: <<3>>,
    ctrl_d: <<4>>,
    esc: <<27>>,
    tab: "\t",
    backspace: <<127>>,
    up: "\e[A",
    down: "\e[B",
    right: "\e[C",
    left: "\e[D"
  }

  def handle_info({:tap, key}, socket) when is_map_key(@key_bytes, key),
    do: transmit(socket, Map.fetch!(@key_bytes, key))

  def handle_info(_message, socket), do: {:noreply, socket}

  defp transmit(socket, bytes) do
    send_input(socket, bytes)
    {:noreply, socket}
  end

  # Input goes to the byte sink; we **never** local-echo — the PTY/shell line
  # discipline decides echo, canonical mode, prompts, password no-echo, etc., and
  # echoed input comes back as ordinary `{:data}`/`{:vt_bytes}` to render once.
  #
  #   * host (dev): write straight to the local PTY.
  #   * device: forward to the host bridge (which writes the PTY).
  #   * device with no host yet: drop (nothing to echo against).
  defp send_input(%{assigns: %{pty: pty}}, bytes) when not is_nil(pty),
    do: Ghostty.PTY.write(pty, bytes)

  defp send_input(%{assigns: %{vt_host: host}}, bytes) when is_pid(host),
    do: send(host, {:vt_input, bytes})

  defp send_input(_socket, _bytes), do: :ok

  # Resize the byte source so the PTY and the rendered grid agree.
  defp resize_source(%{assigns: %{pty: pty}}, cols, rows) when not is_nil(pty),
    do: Ghostty.PTY.resize(pty, cols, rows)

  defp resize_source(%{assigns: %{vt_host: host}}, cols, rows) when is_pid(host),
    do: send(host, {:vt_resize, cols, rows})

  defp resize_source(_socket, _cols, _rows), do: :ok

  defp resize_to(socket, cols, rows) do
    cols = clamp(cols, @min_cols, @max_cols)
    rows = clamp(rows, @min_rows, @max_rows)

    if {cols, rows} == {socket.assigns.cols, socket.assigns.rows} do
      socket
    else
      Terminal.resize(socket.assigns.term, cols, rows)
      resize_source(socket, cols, rows)

      socket
      |> Mob.Socket.assign(:cols, cols)
      |> Mob.Socket.assign(:rows, rows)
      |> ensure_repaint()
    end
  end

  defp parse_wxh(s) do
    with [w, h] <- String.split(s, "x"),
         {wi, ""} <- Integer.parse(w),
         {hi, ""} <- Integer.parse(h) do
      {wi, hi}
    else
      _ -> :error
    end
  end

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  defp status_line(%{vt_host: host}) when is_pid(host), do: "Devbox connected"
  defp status_line(%{pty: pty}) when not is_nil(pty), do: "Local shell"
  defp status_line(_assigns), do: "Waiting for devbox"

  defp status_badge_color(%{vt_host: host}) when is_pid(host), do: 0xFF214332
  defp status_badge_color(%{pty: pty}) when not is_nil(pty), do: 0xFF214332
  defp status_badge_color(_assigns), do: 0xFF3D351E

  defp terminal_meta(assigns), do: "Grid #{grid_label(assigns)}"

  defp grid_label(%{cols: cols, rows: rows}), do: "#{cols}x#{rows}"

  # ── Grid → Canvas ops (cell shape: {grapheme, fg, bg, flags}) ─────────────────

  defp repaint(socket) do
    term = socket.assigns.term
    {cur_col, cur_row} = Terminal.cursor(term)
    width = socket.assigns.cols * @cellw
    height = socket.assigns.rows * @cellh

    ops =
      term
      |> Terminal.cells()
      |> Enum.with_index()
      |> Enum.flat_map(fn {row, r} -> row_ops(row, r) end)

    background = Mob.Canvas.rect(0, 0, width, height, color: @terminal_surface, fill: true)

    Mob.Socket.assign(socket, :draw, [background | ops] ++ [cursor_op(cur_col, cur_row)])
  end

  defp row_ops(row, r) do
    row
    |> Enum.with_index()
    |> Enum.flat_map(fn {cell, c} -> cell_ops(cell, r, c) end)
  end

  defp cell_ops({grapheme, fg, bg, flags}, r, c) do
    x = c * @cellw
    y = r * @cellh

    bg_ops =
      if color = bg_color(bg) do
        [Mob.Canvas.rect(x, y, @cellw, @cellh, color: color, fill: true)]
      else
        []
      end

    text_ops =
      if grapheme != "" do
        [
          Mob.Canvas.text(x, y, grapheme,
            color: fg_color(fg),
            size: @font_size,
            weight: bold_weight(flags),
            family: "Menlo"
          )
        ]
      else
        []
      end

    bg_ops ++ text_ops
  end

  defp cursor_op(col, row) do
    Mob.Canvas.rect(col * @cellw, row * @cellh, @cellw, @cellh, color: @cursor_color, fill: true)
  end

  defp bold_weight(flags) when (flags &&& 1) != 0, do: :bold
  defp bold_weight(_), do: :regular

  # ghostty color `{r, g, b} | nil` -> 0xAARRGGBB int (Mob passes ints through).
  defp argb(nil), do: nil
  defp argb({r, g, b}), do: 0xFF000000 ||| r <<< 16 ||| g <<< 8 ||| b

  # The on-device Ghostty VT surface currently reports its default light theme
  # as explicit white background / black foreground. Treat those as defaults so
  # the Mob terminal owns the mobile dark palette, while still preserving ANSI
  # colors and non-default backgrounds.
  defp bg_color({255, 255, 255}), do: nil
  defp bg_color(color), do: argb(color)

  defp fg_color(nil), do: @default_fg
  defp fg_color({0, 0, 0}), do: @default_fg
  defp fg_color(color), do: argb(color)

  defp ensure_repaint(%{assigns: %{repaint_scheduled?: true}} = socket), do: socket

  defp ensure_repaint(socket) do
    Process.send_after(self(), :repaint, @repaint_ms)
    Mob.Socket.assign(socket, :repaint_scheduled?, true)
  end

  defp shell, do: System.get_env("SHELL") || "/bin/sh"
end
