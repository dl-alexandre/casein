defmodule DevIDE.Test.FakeTmuxAdapter do
  @moduledoc false

  def session_alive?("alive-session"), do: true
  def session_alive?("session-" <> _), do: true
  def session_alive?(_session), do: false

  def create_session(execution_id, _opts), do: {:ok, "session-#{execution_id}"}

  def capture("alive-session"), do: {:ok, "captured pane\n"}
  def capture(_session), do: {:error, :session_not_alive}

  def attach_command(session), do: "tmux attach -t #{session}"

  def send_keys("alive-session", keys) do
    send(test_pid(), {:fake_tmux_keys, "alive-session", keys})
    :ok
  end

  def send_keys(_session, _keys), do: {:error, :session_not_alive}

  def ensure_session(session, cwd) do
    send(test_pid(), {:fake_tmux_ensure_session, session, cwd})
    :ok
  end

  def list_session_windows(session) do
    fake_windows()
    |> Map.get(session, [])
  end

  def new_window(session, opts \\ []) do
    id = Map.get(fake_next_window(), session, "@2")
    name = Keyword.get(opts, :name, "bash")
    send(test_pid(), {:fake_tmux_new_window, session, opts})

    update_fake_windows(session, fn windows ->
      windows =
        Enum.map(windows, &Map.put(&1, :active, false)) ++
          [
            %{
              id: id,
              index: length(windows),
              name: name,
              active: true,
              panes: 1,
              activity: 0,
              current_command: "bash"
            }
          ]

      windows
    end)

    {:ok, id}
  end

  def select_window(session, window_id) do
    send(test_pid(), {:fake_tmux_select_window, session, window_id})

    update_fake_windows(session, fn windows ->
      Enum.map(windows, &Map.put(&1, :active, &1.id == window_id))
    end)

    :ok
  end

  def rename_window(session, window_id, name) do
    send(test_pid(), {:fake_tmux_rename_window, session, window_id, name})

    update_fake_windows(session, fn windows ->
      Enum.map(windows, fn window ->
        if window.id == window_id, do: %{window | name: name}, else: window
      end)
    end)

    :ok
  end

  def kill_window(session, window_id) do
    send(test_pid(), {:fake_tmux_kill_window, session, window_id})

    update_fake_windows(session, fn windows ->
      remaining = Enum.reject(windows, &(&1.id == window_id))

      if Enum.any?(remaining, & &1.active) do
        remaining
      else
        case remaining do
          [first | rest] -> [%{first | active: true} | rest]
          [] -> []
        end
      end
    end)

    :ok
  end

  defp test_pid do
    Application.get_env(:dev_ide, :fake_tmux_test_pid, self())
  end

  defp fake_windows do
    Application.get_env(:dev_ide, :fake_tmux_windows, %{})
  end

  defp fake_next_window do
    Application.get_env(:dev_ide, :fake_tmux_next_window, %{})
  end

  defp update_fake_windows(session, fun) do
    windows = Map.update(fake_windows(), session, fun.([]), fun)
    Application.put_env(:dev_ide, :fake_tmux_windows, windows)
  end
end
