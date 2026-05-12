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

  defp test_pid do
    Application.get_env(:dev_ide, :fake_tmux_test_pid, self())
  end
end
