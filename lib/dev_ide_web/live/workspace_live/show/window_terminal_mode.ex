defmodule CaseinWeb.WorkspaceLive.Show.WindowTerminalMode do
  @moduledoc """
  Active-window terminal helpers.

  Terminals are raw everywhere — there is no governed/raw toggle and no
  per-window mode to remember — so this module no longer tracks per-window
  state. It keeps the Ghostty pane started for the active tmux window and
  exposes the window-name helpers used by the palette, audit metadata, and
  page chrome. Retained as a thin surface so callers (Show, TerminalState,
  palette) keep a stable API.
  """

  alias CaseinWeb.WorkspaceLive.Show

  @type mode :: :raw

  @doc "(Re)start the Ghostty surface for the active pane. Always `:raw`."
  @spec set_mode(Phoenix.LiveView.Socket.t(), mode()) :: Phoenix.LiveView.Socket.t()
  def set_mode(socket, :raw), do: Show.start_ghostty_terminal(socket)

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
        Show.start_ghostty_terminal(socket)

      _ ->
        socket
    end
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

  defp window_name_for_id(socket, window_id) when is_binary(window_id) do
    (socket.assigns[:tmux_windows] || [])
    |> Enum.find_value(fn window ->
      if window.id == window_id, do: window.name
    end)
  end

  defp window_name_for_id(_socket, _window_id), do: nil
end
