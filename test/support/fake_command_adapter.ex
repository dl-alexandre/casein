defmodule DevIDE.Test.FakeCommandAdapter do
  @moduledoc false
  @behaviour DevIDE.Commands

  @impl true
  def spawn(root, argv, subscriber) do
    ref = make_ref()
    send(test_pid(), {:fake_command_spawned, root, argv})
    send(subscriber, {:cmd_data, ref, :stdout, "ok\n"})
    send(subscriber, {:cmd_exit, ref, 0})
    {:ok, ref, %{ref: ref}}
  end

  @impl true
  def kill(_handle), do: :ok

  defp test_pid do
    Application.get_env(:dev_ide, :fake_command_test_pid, self())
  end
end
