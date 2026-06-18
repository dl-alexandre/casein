defmodule DevIdeWeb.WorkspaceLive.Show.WindowTerminalMode do
  @moduledoc """
  Per-window terminal state.

  Terminals are raw everywhere, so there is no governed/raw toggle anymore.
  The remaining per-window machinery only tracks which windows the operator
  has explicitly opened in raw (all of them, in practice) and keeps the
  Ghostty pane started for the active window. Retained as a thin surface so
  callers (Show, TerminalState, palette) keep a stable API.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  alias DevIdeWeb.WorkspaceLive.Show
  alias DevIdeWeb.WorkspaceLive.Show.TerminalState

  @type mode :: :raw

  def reset(socket) do
    socket
    |> assign(:window_terminal_modes, %{})
    |> assign(:window_terminal_mode_names, %{})
    |> refresh_ui()
  end

  def record_current(socket, :raw) do
    case socket.assigns[:tmux_active_window_id] do
      id when is_binary(id) and id != "" ->
        modes = socket.assigns[:window_terminal_modes] || %{}
        names = socket.assigns[:window_terminal_mode_names] || %{}
        window_name = active_window_name(socket)

        names =
          if is_binary(window_name) and window_name != "" do
            Map.put(names, window_name, :raw)
          else
            names
          end

        socket
        |> assign(:window_terminal_modes, Map.put(modes, id, :raw))
        |> assign(:window_terminal_mode_names, names)
        |> refresh_ui()

      _ ->
        socket
    end
  end

  def forget_window(socket, window_id) when is_binary(window_id) do
    modes = socket.assigns[:window_terminal_modes] || %{}
    names = socket.assigns[:window_terminal_mode_names] || %{}
    window_name = window_name_for_id(socket, window_id)

    names =
      if is_binary(window_name) and window_name != "" do
        Map.delete(names, window_name)
      else
        names
      end

    socket
    |> assign(:window_terminal_modes, Map.delete(modes, window_id))
    |> assign(:window_terminal_mode_names, names)
    |> refresh_ui()
  end

  @doc """
  Raw is reachable everywhere now, so there is nothing to strip. Retained as a
  no-op for callers in the mount/mode-refresh path.
  """
  def strip_disallowed_raw(socket), do: socket

  def restore_from_client(socket, payload) when is_map(payload) do
    {modes, names, new_windows_raw?} = decode_storage_payload(payload)

    socket =
      socket
      |> assign(:window_terminal_modes, modes)
      |> assign(:window_terminal_mode_names, names)
      |> assign(:new_windows_default_raw?, new_windows_raw?)
      |> apply_for_active_window()

    refresh_ui(socket)
  end

  def set_new_windows_default_raw?(socket, enabled) when is_boolean(enabled) do
    socket
    |> assign(:new_windows_default_raw?, enabled)
    |> refresh_ui()
  end

  @spec set_mode(Phoenix.LiveView.Socket.t(), mode()) :: Phoenix.LiveView.Socket.t()
  def set_mode(socket, :raw) do
    socket
    |> apply_mode(:raw)
    |> record_current(:raw)
  end

  def on_active_window_changed(socket, prev_window, next_window) do
    cond do
      not is_binary(next_window) or next_window == "" -> socket
      prev_window == next_window -> socket
      true -> apply_for_active_window(socket)
    end
  end

  def apply_for_active_window(socket) do
    case socket.assigns[:tmux_active_window_id] do
      id when is_binary(id) and id != "" ->
        apply_mode(socket, mode_for_window(socket, id))

      _ ->
        socket
    end
  end

  def stash_url_mode(socket, mode) when mode in ["raw", :raw] do
    assign(socket, :pending_url_terminal_mode, :raw)
  end

  def stash_url_mode(socket, _mode), do: assign(socket, :pending_url_terminal_mode, nil)

  @doc "Apply `?mode=raw` once tmux topology is hydrated (survives async mount hydration)."
  def apply_pending_url_mode(socket) do
    case socket.assigns[:pending_url_terminal_mode] do
      :raw ->
        if topology_ready?(socket) do
          socket
          |> assign(:pending_url_terminal_mode, nil)
          |> set_mode(:raw)
        else
          socket
        end

      _ ->
        socket
    end
  end

  def rename_window(socket, window_id, new_name)
      when is_binary(window_id) and is_binary(new_name) do
    old_name = window_name_for_id(socket, window_id)
    new_name = String.trim(new_name)
    names = socket.assigns[:window_terminal_mode_names] || %{}
    modes = socket.assigns[:window_terminal_modes] || %{}

    names =
      names
      |> migrate_name_key(old_name, new_name)
      |> sync_name_from_window_id(window_id, new_name, modes)

    socket
    |> assign(:window_terminal_mode_names, names)
    |> annotate_session_tabs()
    |> sync_client_storage()
  end

  @doc "Mode saved (or defaulted) for a tmux window — used in deep links."
  def mode_for_window_id(socket, window_id) when is_binary(window_id) do
    mode_for_window(socket, window_id)
  end

  def query_mode_param(socket, window_id) when is_binary(window_id) do
    case mode_for_window_id(socket, window_id) do
      :raw -> "raw"
      _ -> nil
    end
  end

  def annotate_session_tabs(socket) do
    sid = socket.assigns[:terminal_sid]

    tabs =
      (socket.assigns[:session_tabs] || [])
      |> Enum.map(fn tab ->
        if tab.id == sid do
          %{tab | windows: annotate_windows(socket, tab.windows)}
        else
          tab
        end
      end)

    assign(socket, :session_tabs, tabs)
  end

  def active_window_name(socket) do
    window_name_for_id(socket, socket.assigns[:tmux_active_window_id])
  end

  def active_window_metadata(socket) do
    %{
      "tmux_window_id" => socket.assigns[:tmux_active_window_id],
      "tmux_window_name" => active_window_name(socket)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  def decode_storage_payload(payload) when is_map(payload) do
    cond do
      Map.has_key?(payload, "modes") or Map.has_key?(payload, :modes) ->
        modes = Map.get(payload, "modes") || Map.get(payload, :modes) || %{}
        names = Map.get(payload, "names") || Map.get(payload, :names) || %{}

        new_windows_raw? =
          Map.get(payload, "new_windows_raw") == true or
            Map.get(payload, :new_windows_raw) == true

        {decode_modes(modes), decode_modes(names), new_windows_raw?}

      true ->
        {decode_modes(payload), %{}, false}
    end
  end

  def decode_modes(modes) when is_map(modes) do
    Enum.reduce(modes, %{}, fn {window_key, mode}, acc ->
      case normalize_mode_string(mode) do
        nil -> acc
        atom -> Map.put(acc, to_string(window_key), atom)
      end
    end)
  end

  def encode_modes(modes) when is_map(modes) do
    Map.new(modes, fn {window_key, mode} -> {window_key, Atom.to_string(mode)} end)
  end

  def window_mode_flags(socket, window) when is_map(window) do
    window_id = Map.get(window, :id) || Map.get(window, "id")
    window_name = Map.get(window, :name) || Map.get(window, "name")

    %{raw_remembered?: explicit_mode(socket, window_id, window_name) == :raw}
  end

  defp annotate_windows(socket, windows) when is_list(windows) do
    Enum.map(windows, fn window ->
      Map.merge(window, window_mode_flags(socket, window))
    end)
  end

  defp annotate_windows(_socket, windows), do: windows

  defp explicit_mode(socket, window_id, window_name) do
    modes = socket.assigns[:window_terminal_modes] || %{}
    names = socket.assigns[:window_terminal_mode_names] || %{}

    cond do
      is_binary(window_id) and Map.has_key?(modes, window_id) ->
        Map.get(modes, window_id)

      is_binary(window_name) and window_name != "" and Map.has_key?(names, window_name) ->
        Map.get(names, window_name)

      true ->
        nil
    end
  end

  defp mode_for_window(socket, window_id) do
    window_name = window_name_for_id(socket, window_id)

    case explicit_mode(socket, window_id, window_name) do
      nil -> :raw
      mode -> mode
    end
  end

  defp window_name_for_id(socket, window_id) when is_binary(window_id) do
    (socket.assigns[:tmux_windows] || [])
    |> Enum.find_value(fn window ->
      if window.id == window_id, do: window.name
    end)
  end

  defp window_name_for_id(_socket, _window_id), do: nil

  defp topology_ready?(socket) do
    socket.assigns[:tmux_topology_version] not in [nil, 0] and
      is_binary(socket.assigns[:tmux_active_window_id]) and
      socket.assigns[:tmux_active_window_id] != ""
  end

  defp migrate_name_key(names, old_name, new_name)
       when is_binary(old_name) and old_name != "" and is_binary(new_name) and new_name != "" do
    case Map.pop(names, old_name) do
      {nil, _} -> names
      {mode, rest} -> Map.put(rest, new_name, mode)
    end
  end

  defp migrate_name_key(names, _old_name, _new_name), do: names

  defp sync_name_from_window_id(names, window_id, new_name, modes)
       when is_binary(new_name) and new_name != "" do
    case Map.get(modes, window_id) do
      :raw -> Map.put(names, new_name, :raw)
      _ -> names
    end
  end

  defp sync_name_from_window_id(names, _window_id, _new_name, _modes), do: names

  defp apply_mode(socket, :raw) do
    if socket.assigns[:terminal_mode] in [:raw, :raw_ghostty] do
      Show.start_ghostty_terminal(socket)
    else
      transition(socket)
    end
  end

  defp normalize_mode_string("raw"), do: :raw
  defp normalize_mode_string(:raw), do: :raw
  defp normalize_mode_string(_), do: nil

  defp transition(socket) do
    socket
    |> Show.cleanup_ghostty_resources_if_leaving()
    |> Show.start_ghostty_terminal()
    |> Show.audit_terminal_mode_transition(socket.assigns[:terminal_mode], :raw)
    |> assign(:terminal_mode, :raw)
    |> Show.refresh_terminal_workspace_capability()
  end

  defp refresh_ui(socket) do
    socket
    |> annotate_session_tabs()
    |> TerminalState.assign_tmux_window_tabs()
    |> sync_client_storage()
  end

  defp sync_client_storage(socket) do
    if connected?(socket) do
      Phoenix.LiveView.push_event(socket, "terminal:window_modes", %{
        "workspace_id" => socket.assigns.workspace.id,
        "terminal_sid" => socket.assigns[:terminal_sid],
        "modes" => encode_modes(socket.assigns[:window_terminal_modes] || %{}),
        "names" => encode_modes(socket.assigns[:window_terminal_mode_names] || %{}),
        "new_windows_raw" => socket.assigns[:new_windows_default_raw?] == true
      })
    else
      socket
    end
  end
end
