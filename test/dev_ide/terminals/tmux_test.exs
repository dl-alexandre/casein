defmodule DevIDE.Terminals.TmuxTest do
  use ExUnit.Case, async: false

  alias DevIDE.Terminals.Tmux
  alias DevIDE.Terminals.TmuxRunner

  setup do
    workspace_source = Application.get_env(:dev_ide, :workspace_source)
    tmux_host_shell = Application.get_env(:dev_ide, :tmux_host_shell)
    tmux_config_file = Application.get_env(:tmux_ctl, :config_file)
    env_host_shell = System.get_env("DEV_IDE_TMUX_HOST_SHELL")
    path = System.get_env("PATH")

    on_exit(fn ->
      put_or_delete_env("DEV_IDE_TMUX_HOST_SHELL", env_host_shell)
      put_or_delete_env("PATH", path)
      put_or_delete_app_env(:workspace_source, workspace_source)
      put_or_delete_app_env(:tmux_host_shell, tmux_host_shell)
      put_or_delete_tmux_ctl_env(:config_file, tmux_config_file)
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

  test "targeted commands stay on host and use config when the tmux session already lives there" do
    bin_dir =
      Path.join(System.tmp_dir!(), "devide-tmux-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(bin_dir)
    tmux_bin = Path.join(bin_dir, "tmux")
    config_file = Path.join(bin_dir, "devide.conf")
    File.write!(config_file, "set-option -g status off\n")

    File.write!(tmux_bin, """
    #!/bin/sh
    if [ "$1" = "has-session" ]; then exit 0; fi
    exit 1
    """)

    File.chmod!(tmux_bin, 0o755)

    Application.put_env(:dev_ide, :workspace_source, DevIDE.Test.WrappingWorkspaceSource)
    Application.put_env(:dev_ide, :tmux_host_shell, false)
    Application.put_env(:tmux_ctl, :config_file, config_file)
    System.put_env("PATH", bin_dir <> ":" <> (System.get_env("PATH") || ""))

    assert [
             "tmux",
             "-f",
             ^config_file,
             "new-window",
             "-t",
             "devide_alpha_u-dev",
             "-c",
             "/workspace"
           ] =
             TmuxRunner.argv(
               ["new-window", "-t", "devide_alpha_u-dev", "-c", "/workspace"],
               cwd: "/host/workspace"
             )
  end

  test "directory_inventory parses tagged window/pane lines grouped by session" do
    bin_dir =
      Path.join(System.tmp_dir!(), "devide-tmux-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(bin_dir)
    tmux_bin = Path.join(bin_dir, "tmux")

    # One chained invocation prints both listings; window name is the last
    # field so embedded pipes survive.
    File.write!(tmux_bin, """
    #!/bin/sh
    printf 'W|devide_a_u-1|@1|0|1|111|bash|shell\\n'
    printf 'W|devide_a_u-1|@2|1|0|222|mix|tests | ci\\n'
    printf 'W|devide_b_u-2|@1|0|1|333|claude|agent\\n'
    printf 'P|devide_a_u-1|1|/workspace/apps/web\\n'
    printf 'P|devide_b_u-2|0|/workspace\\n'
    """)

    File.chmod!(tmux_bin, 0o755)

    Application.put_env(:dev_ide, :workspace_source, DevIDE.Test.WrappingWorkspaceSource)
    Application.put_env(:dev_ide, :tmux_host_shell, true)
    System.put_env("PATH", bin_dir <> ":" <> (System.get_env("PATH") || ""))

    assert {:ok, %{windows: windows, panes: panes}} = Tmux.directory_inventory()

    assert [
             %{id: "@1", index: 0, name: "shell", active: true, activity: 111},
             %{id: "@2", index: 1, name: "tests | ci", active: false, current_command: "mix"}
           ] = windows["devide_a_u-1"]

    assert [%{id: "@1", name: "agent", current_command: "claude"}] = windows["devide_b_u-2"]
    assert [%{active: true, current_path: "/workspace/apps/web"}] = panes["devide_a_u-1"]
    assert [%{active: false, current_path: "/workspace"}] = panes["devide_b_u-2"]
  end

  describe "tail_lines/2 (capture_scrollback :lines tailing)" do
    @sample "l1\nl2\nl3\nl4\nl5"

    test "nil returns the output unchanged (full history)" do
      assert Tmux.tail_lines(@sample, nil) == @sample
    end

    test "non-positive or non-integer N returns the output unchanged" do
      assert Tmux.tail_lines(@sample, 0) == @sample
      assert Tmux.tail_lines(@sample, -3) == @sample
      assert Tmux.tail_lines(@sample, "2") == @sample
    end

    test "keeps only the last N logical lines" do
      assert Tmux.tail_lines(@sample, 2) == "l4\nl5"
      assert Tmux.tail_lines(@sample, 1) == "l5"
    end

    test "N larger than the line count returns everything" do
      assert Tmux.tail_lines(@sample, 99) == @sample
    end

    test "preserves a trailing blank line as a line" do
      # capture-pane output often ends with a newline; the empty final segment
      # counts as a line so the tail window is accurate.
      assert Tmux.tail_lines("a\nb\n", 2) == "b\n"
    end
  end

  defp put_or_delete_env(name, nil), do: System.delete_env(name)
  defp put_or_delete_env(name, value), do: System.put_env(name, value)

  defp put_or_delete_app_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp put_or_delete_app_env(key, value), do: Application.put_env(:dev_ide, key, value)

  defp put_or_delete_tmux_ctl_env(key, nil), do: Application.delete_env(:tmux_ctl, key)
  defp put_or_delete_tmux_ctl_env(key, value), do: Application.put_env(:tmux_ctl, key, value)
end
