defmodule DevIdeWeb.WorkspaceLive.Show.WindowTerminalMode do
  @moduledoc false

  import Phoenix.Component

  alias DevIDE.Terminals.ModePolicy

  @raw_modes [:raw, :raw_ghostty]

  def stash_url_mode(socket, mode) when mode in ["raw", "raw_ghostty", "governed"] do
    assign(socket, :pending_url_terminal_mode, mode)
  end

  def stash_url_mode(socket, _mode), do: socket

  def apply_pending_url_mode(socket) do
    case socket.assigns[:pending_url_terminal_mode] do
      "governed" ->
        socket
        |> set_mode(:governed)
        |> assign(:pending_url_terminal_mode, nil)

      mode when mode in ["raw", "raw_ghostty"] ->
        if raw_allowed?(socket) do
          socket
          |> set_mode(:raw)
          |> assign(:pending_url_terminal_mode, nil)
        else
          assign(socket, :pending_url_terminal_mode, nil)
        end

      _ ->
        socket
    end
  end

  def set_mode(socket, mode) when mode in [:raw, :raw_ghostty, :governed] do
    window_id = socket.assigns[:tmux_active_window_id]
    mode = normalize_mode(mode)

    socket
    |> assign(:terminal_mode, mode)
    |> assign_window_mode(window_id, mode)
  end

  def strip_disallowed_raw(socket) do
    if socket.assigns[:terminal_mode] in @raw_modes and not raw_allowed?(socket) do
      set_mode(socket, :governed)
    else
      socket
    end
  end

  def active_window_metadata(socket) do
    case active_window(socket.assigns) do
      nil ->
        %{}

      window ->
        %{
          "tmux_window_id" => Map.get(window, :id),
          "tmux_window_name" => Map.get(window, :name)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
        |> Map.new()
    end
  end

  def active_window_name(%{assigns: assigns}) do
    case active_window(assigns) do
      nil -> nil
      window -> Map.get(window, :name)
    end
  end

  def active_window_name(assigns) when is_map(assigns),
    do: active_window_name(%{assigns: assigns})

  defp assign_window_mode(socket, nil, _mode), do: socket

  defp assign_window_mode(socket, window_id, mode) do
    modes =
      socket.assigns
      |> Map.get(:window_terminal_modes, %{})
      |> Map.put(window_id, mode)

    names =
      socket.assigns
      |> Map.get(:window_terminal_mode_names, %{})
      |> Map.put(window_id, active_window_name(socket) || window_id)

    socket
    |> assign(:window_terminal_modes, modes)
    |> assign(:window_terminal_mode_names, names)
  end

  defp normalize_mode(:raw_ghostty), do: :raw
  defp normalize_mode(mode), do: mode

  defp raw_allowed?(socket) do
    ModePolicy.raw_terminal_allowed?(socket.assigns[:workspace_mode], socket.assigns[:host_id])
  end

  defp active_window(assigns) do
    active_id = Map.get(assigns, :tmux_active_window_id)

    assigns
    |> Map.get(:tmux_windows, [])
    |> Enum.find(&(Map.get(&1, :id) == active_id))
  end
end
