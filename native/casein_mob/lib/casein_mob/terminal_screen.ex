defmodule CaseinMob.TerminalScreen do
  @moduledoc """
  Read-only view of one server-owned disposable mobile terminal.

  The screen never starts a shell, accepts keyboard input, or talks to
  `HostBridge`. Bytes arrive only from `SessionClient` after an authenticated
  `mobile_terminal_v1` baseline. Any lifecycle gap clears the VT surface and a
  fresh baseline is required before output is shown again.
  """

  use Mob.Screen

  import Bitwise

  alias CaseinMob.{SessionClient, SessionConfig, Terminal}

  @cellw 9
  @cellh 18
  @font_size 14
  @default_cols 80
  @default_rows 24
  @min_cols 20
  @max_cols 400
  @min_rows 4
  @max_rows 200
  @repaint_ms 16

  @terminal_bg 0xFF080A0C
  @terminal_surface 0xFF101214
  @terminal_border 0xFF31363B
  @default_fg 0xFFE7ECEF
  @cursor_color 0xFFE0E0E0

  def mount(_params, _session, socket) do
    workspace_id = selected_workspace_id()
    origin = active_origin()

    if is_binary(workspace_id), do: SessionClient.watch_terminal(workspace_id, self())

    socket =
      socket
      |> Mob.Socket.assign(:term, Terminal.new(@default_cols, @default_rows))
      |> Mob.Socket.assign(:cols, @default_cols)
      |> Mob.Socket.assign(:rows, @default_rows)
      |> Mob.Socket.assign(:workspace_id, workspace_id)
      |> Mob.Socket.assign(:origin_id, origin.id)
      |> Mob.Socket.assign(:origin_name, origin.name)
      |> Mob.Socket.assign(:expires_at, nil)
      |> Mob.Socket.assign(:status, if(workspace_id, do: :connecting, else: :unavailable))
      |> Mob.Socket.assign(:baseline_ready?, false)
      |> Mob.Socket.assign(:fresh_baseline_generation, nil)
      |> Mob.Socket.assign(:repaint_scheduled?, false)
      |> Mob.Socket.assign(:draw, [])

    {:ok, repaint(socket)}
  end

  def render(assigns) do
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
          text={status_label(assigns.status)}
          text_size={:xs}
          text_color={0xFFE7ECEF}
          background={status_color(assigns.status)}
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
        <Text text={metadata_line(assigns)} text_size={12.0} text_color={0xFFE7ECEF} padding={4} />
        <Text
          text="Read-only · input is disabled"
          text_size={11.0}
          text_color={0xFF9CA3AF}
          padding={4}
        />
        <Box
          id="terminal-surface"
          fresh_baseline_generation={assigns.fresh_baseline_generation}
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
          <Canvas width={canvas_w} height={canvas_h} draw={assigns.draw} />
        </Box>
      </Column>
    </Column>
    """
  end

  def handle_info({:mobile_terminal_baseline, metadata, bytes}, socket)
      when is_map(metadata) and is_binary(bytes) do
    term = Terminal.reset(socket.assigns.term, socket.assigns.cols, socket.assigns.rows)
    :ok = Terminal.write(term, bytes)

    {:noreply,
     socket
     |> Mob.Socket.assign(:term, term)
     |> Mob.Socket.assign(:origin_id, Map.get(metadata, :origin_id))
     |> Mob.Socket.assign(:origin_name, Map.get(metadata, :origin_name) || "Unknown origin")
     |> Mob.Socket.assign(:workspace_id, Map.get(metadata, :workspace_id))
     |> Mob.Socket.assign(:expires_at, Map.get(metadata, :expires_at))
     |> Mob.Socket.assign(:status, :live)
     |> Mob.Socket.assign(:baseline_ready?, true)
     |> Mob.Socket.assign(
       :fresh_baseline_generation,
       Map.get(metadata, :fresh_baseline_generation)
     )
     |> ensure_repaint()}
  end

  def handle_info({:mobile_terminal_output, bytes}, %{assigns: %{baseline_ready?: true}} = socket)
      when is_binary(bytes) do
    :ok = Terminal.write(socket.assigns.term, bytes)
    {:noreply, ensure_repaint(socket)}
  end

  def handle_info({:mobile_terminal_output, _bytes}, socket), do: {:noreply, socket}

  def handle_info({:mobile_terminal_status, workspace_id, status, metadata}, socket) do
    socket =
      socket
      |> Mob.Socket.assign(:workspace_id, workspace_id)
      |> Mob.Socket.assign(:status, status)
      |> maybe_assign_metadata(metadata)

    if terminal_visible?(status), do: {:noreply, socket}, else: {:noreply, cover(socket)}
  end

  def handle_info({:change, :term_size, wxh}, socket) when is_binary(wxh) do
    case parse_wxh(wxh) do
      {w, h} -> {:noreply, resize_to(socket, div(w, @cellw), div(h, @cellh))}
      :error -> {:noreply, socket}
    end
  end

  def handle_info({:resize_terminal, cols, rows}, socket)
      when is_integer(cols) and is_integer(rows),
      do: {:noreply, resize_to(socket, cols, rows)}

  def handle_info(:repaint, socket) do
    {:noreply, socket |> Mob.Socket.assign(:repaint_scheduled?, false) |> repaint()}
  end

  def handle_info(message, socket) when message in [:app_background, :background] do
    SessionClient.terminal_background()
    {:noreply, cover(socket)}
  end

  def handle_info(message, socket) when message in [:app_foreground, :foreground] do
    SessionClient.terminal_foreground()
    {:noreply, socket |> Mob.Socket.assign(:status, :refreshing) |> cover()}
  end

  def handle_info({:app_lifecycle, :background}, socket), do: handle_info(:app_background, socket)
  def handle_info({:app_lifecycle, :foreground}, socket), do: handle_info(:app_foreground, socket)

  def handle_info({:tap, :back}, socket) do
    SessionClient.unwatch_terminal(self())
    {:noreply, Mob.Socket.pop_screen(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  def terminate(_reason, socket) do
    SessionClient.unwatch_terminal(self())
    Terminal.close(socket.assigns.term)
    :ok
  end

  defp selected_workspace_id do
    case SessionConfig.resume_context() do
      %{workspace_id: workspace_id} when is_binary(workspace_id) and workspace_id != "" ->
        workspace_id

      _ ->
        Enum.find(SessionConfig.pinned_workspaces(), &(is_binary(&1) and &1 != ""))
    end
  end

  defp active_origin do
    case SessionConfig.connection() do
      {:ok, profile} ->
        %{
          id: Map.get(profile, :origin_id),
          name: Map.get(profile, :display_name) || Map.get(profile, :url) || "Unknown origin"
        }

      :error ->
        %{id: nil, name: "No active origin"}
    end
  end

  defp maybe_assign_metadata(socket, metadata) when is_map(metadata) do
    socket
    |> maybe_assign(:origin_id, Map.get(metadata, :origin_id))
    |> maybe_assign(:origin_name, Map.get(metadata, :origin_name))
    |> maybe_assign(:expires_at, Map.get(metadata, :expires_at))
  end

  defp maybe_assign_metadata(socket, _metadata), do: socket

  defp maybe_assign(socket, _key, nil), do: socket
  defp maybe_assign(socket, key, value), do: Mob.Socket.assign(socket, key, value)

  defp terminal_visible?(:live), do: true
  defp terminal_visible?(_status), do: false

  defp cover(socket) do
    term = Terminal.reset(socket.assigns.term, socket.assigns.cols, socket.assigns.rows)

    socket
    |> Mob.Socket.assign(:term, term)
    |> Mob.Socket.assign(:baseline_ready?, false)
    |> Mob.Socket.assign(:fresh_baseline_generation, nil)
    |> repaint()
  end

  defp resize_to(socket, cols, rows) do
    cols = clamp(cols, @min_cols, @max_cols)
    rows = clamp(rows, @min_rows, @max_rows)

    if {cols, rows} == {socket.assigns.cols, socket.assigns.rows} do
      socket
    else
      :ok = Terminal.resize(socket.assigns.term, cols, rows)

      socket
      |> Mob.Socket.assign(:cols, cols)
      |> Mob.Socket.assign(:rows, rows)
      |> ensure_repaint()
    end
  end

  defp parse_wxh(value) do
    with [width, height] <- String.split(value, "x"),
         {width, ""} <- Integer.parse(width),
         {height, ""} <- Integer.parse(height) do
      {width, height}
    else
      _ -> :error
    end
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  defp status_label(:live), do: "Live"
  defp status_label(:awaiting_baseline), do: "Securing stream"
  defp status_label(:refresh), do: "Refreshing"
  defp status_label(:refreshing), do: "Refreshing"
  defp status_label(:create), do: "Opening"
  defp status_label(:connecting), do: "Connecting"
  defp status_label(:backgrounded), do: "Covered"
  defp status_label(:unavailable), do: "Unavailable"
  defp status_label({:resync, _reason}), do: "Resyncing"
  defp status_label({:cutoff, _reason}), do: "Closed"
  defp status_label({:error, _reason}), do: "Unavailable"
  defp status_label(_status), do: "Offline"

  defp status_color(:live), do: 0xFF214332
  defp status_color({:error, _reason}), do: 0xFF5A2525
  defp status_color({:cutoff, _reason}), do: 0xFF5A2525
  defp status_color(_status), do: 0xFF3D351E

  defp metadata_line(assigns) do
    workspace = assigns.workspace_id || "No authorized workspace"
    expiry = assigns.expires_at || "unknown expiry"
    "#{assigns.origin_name} · #{workspace} · expires #{expiry}"
  end

  defp repaint(socket) do
    term = socket.assigns.term
    {cursor_col, cursor_row} = Terminal.cursor(term)
    width = socket.assigns.cols * @cellw
    height = socket.assigns.rows * @cellh

    cells =
      term
      |> Terminal.cells()
      |> Enum.with_index()
      |> Enum.flat_map(fn {row, row_index} -> row_ops(row, row_index) end)

    background = Mob.Canvas.rect(0, 0, width, height, color: @terminal_surface, fill: true)
    cursor = cursor_op(cursor_col, cursor_row)

    draw =
      if socket.assigns.baseline_ready?, do: [background | cells] ++ [cursor], else: [background]

    Mob.Socket.assign(socket, :draw, draw)
  end

  defp row_ops(row, row_index) do
    row
    |> Enum.with_index()
    |> Enum.flat_map(fn {cell, column_index} -> cell_ops(cell, row_index, column_index) end)
  end

  defp cell_ops({grapheme, foreground, background, flags}, row, column) do
    x = column * @cellw
    y = row * @cellh

    background_ops =
      if color = background_color(background),
        do: [Mob.Canvas.rect(x, y, @cellw, @cellh, color: color, fill: true)],
        else: []

    text_ops =
      if grapheme == "" do
        []
      else
        [
          Mob.Canvas.text(x, y, grapheme,
            color: foreground_color(foreground),
            size: @font_size,
            weight: bold_weight(flags),
            family: "Menlo"
          )
        ]
      end

    background_ops ++ text_ops
  end

  defp cursor_op(column, row) do
    Mob.Canvas.rect(column * @cellw, row * @cellh, @cellw, @cellh,
      color: @cursor_color,
      fill: true
    )
  end

  defp bold_weight(flags) when (flags &&& 1) != 0, do: :bold
  defp bold_weight(_flags), do: :regular

  defp argb(nil), do: nil
  defp argb({red, green, blue}), do: 0xFF000000 ||| red <<< 16 ||| green <<< 8 ||| blue
  defp background_color({255, 255, 255}), do: nil
  defp background_color(color), do: argb(color)
  defp foreground_color(nil), do: @default_fg
  defp foreground_color({0, 0, 0}), do: @default_fg
  defp foreground_color(color), do: argb(color)

  defp ensure_repaint(%{assigns: %{repaint_scheduled?: true}} = socket), do: socket

  defp ensure_repaint(socket) do
    Process.send_after(self(), :repaint, @repaint_ms)
    Mob.Socket.assign(socket, :repaint_scheduled?, true)
  end
end
