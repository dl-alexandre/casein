defmodule DevIDE.Terminals.TmuxTest do
  use ExUnit.Case, async: false

  alias DevIDE.Terminals.Tmux

  setup do
    workspace_source = Application.get_env(:dev_ide, :workspace_source)
    tmux_host_shell = Application.get_env(:dev_ide, :tmux_host_shell)
    env_host_shell = System.get_env("DEV_IDE_TMUX_HOST_SHELL")
    path = System.get_env("PATH")

    on_exit(fn ->
      put_or_delete_env("DEV_IDE_TMUX_HOST_SHELL", env_host_shell)
      put_or_delete_env("PATH", path)
      put_or_delete_app_env(:workspace_source, workspace_source)
      put_or_delete_app_env(:tmux_host_shell, tmux_host_shell)
    end)

    :ok
  end

  test "session_name uses the devide_ prefix" do
    assert "devide_" <> _ = Tmux.session_name("alice", "u-1")
  end

  test "sanitizes unsafe characters in workspace name and sid" do
    name = Tmux.session_name("alice; rm -rf /", "u 1$")
    assert name =~ ~r/^devide_[A-Za-z0-9_\-]+_[A-Za-z0-9_\-]+$/
  end

  test "is deterministic for the same inputs" do
    assert Tmux.session_name("alice", "u-1") == Tmux.session_name("alice", "u-1")
  end

  test "resize_pane rejects invalid directions and amounts" do
    assert Tmux.resize_amount_default() == 5
    assert Tmux.resize_amount_max() == 50

    assert {:error, :invalid_resize} = Tmux.resize_pane("devide_alpha_ws-1", "%1", "side", 5)
    assert {:error, :invalid_amount} = Tmux.resize_pane("devide_alpha_ws-1", "%1", "left", 0)
    assert {:error, :invalid_amount} = Tmux.resize_pane("devide_alpha_ws-1", "%1", "left", 51)
  end

  test "host shell mode runs topology commands against host tmux" do
    bin_dir =
      Path.join(System.tmp_dir!(), "devide-tmux-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(bin_dir)
    tmux_bin = Path.join(bin_dir, "tmux")

    File.write!(tmux_bin, """
    #!/bin/sh
    printf '@1|0|shell|1|1|123|bash\\n'
    """)

    File.chmod!(tmux_bin, 0o755)

    Application.put_env(:dev_ide, :workspace_source, DevIDE.Test.WrappingWorkspaceSource)
    Application.put_env(:dev_ide, :tmux_host_shell, true)
    System.put_env("PATH", bin_dir <> ":" <> (System.get_env("PATH") || ""))

    assert [
             %{
               id: "@1",
               index: 0,
               name: "shell",
               active: true,
               panes: 1,
               activity: 123,
               current_command: "bash"
             }
           ] = Tmux.list_session_windows("devide_alpha_u-dev")
  end

  defp put_or_delete_env(name, nil), do: System.delete_env(name)
  defp put_or_delete_env(name, value), do: System.put_env(name, value)

  defp put_or_delete_app_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp put_or_delete_app_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
