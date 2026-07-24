defmodule Casein.Terminals.TmuxTest do
  use Casein.TestCase, async: false

  alias Casein.Terminals.Tmux
  alias Casein.Terminals.TmuxRunner

  setup do
    workspace_source = Application.get_env(:casein, :workspace_source)
    tmux_host_shell = Application.get_env(:casein, :tmux_host_shell)
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
    printf '@1|0|1|shell|1|1|123|bash\\n'
    """)

    File.chmod!(tmux_bin, 0o755)

    Application.put_env(:casein, :workspace_source, Casein.Test.WrappingWorkspaceSource)
    Application.put_env(:casein, :tmux_host_shell, true)
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

    # has-session may be preceded by the sandbox server label (`-L devide_test`),
    # so match the subcommand wherever it lands in argv.
    File.write!(tmux_bin, """
    #!/bin/sh
    for a in "$@"; do
      [ "$a" = "has-session" ] && exit 0
    done
    exit 1
    """)

    File.chmod!(tmux_bin, 0o755)

    Application.put_env(:casein, :workspace_source, Casein.Test.WrappingWorkspaceSource)
    Application.put_env(:casein, :tmux_host_shell, false)
    Application.put_env(:tmux_ctl, :config_file, config_file)
    System.put_env("PATH", bin_dir <> ":" <> (System.get_env("PATH") || ""))

    # Host invocations carry the configured server label (`-L devide_test` in :test).
    expected =
      [tmux_bin] ++
        Casein.Terminals.TmuxServer.args() ++
        ["-f", config_file, "new-window", "-t", "devide_alpha_u-dev", "-c", "/workspace"]

    assert expected ==
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
    printf 'W|devide_a_u-1|@1|0|1|111|bash|1|shell\\n'
    printf 'W|devide_a_u-1|@2|1|0|222|mix|0|tests | ci\\n'
    printf 'W|devide_b_u-2|@1|0|1|333|claude|1|agent\\n'
    printf 'P|devide_a_u-1|@2|%%3|1|/workspace/apps/web\\n'
    printf 'P|devide_b_u-2|@1|%%0|0|/workspace\\n'
    """)

    File.chmod!(tmux_bin, 0o755)

    Application.put_env(:casein, :workspace_source, Casein.Test.WrappingWorkspaceSource)
    Application.put_env(:casein, :tmux_host_shell, true)
    System.put_env("PATH", bin_dir <> ":" <> (System.get_env("PATH") || ""))

    assert {:ok, %{windows: windows, panes: panes}} = Tmux.directory_inventory()

    assert [
             %{id: "@1", index: 0, name: "shell", active: true, activity: 111},
             %{id: "@2", index: 1, name: "tests | ci", active: false, current_command: "mix"}
           ] = windows["devide_a_u-1"]

    assert [%{id: "@1", name: "agent", current_command: "claude"}] = windows["devide_b_u-2"]

    assert [
             %{
               window_id: "@2",
               id: "%3",
               active: true,
               current_path: "/workspace/apps/web"
             }
           ] = panes["devide_a_u-1"]

    assert [%{window_id: "@1", id: "%0", active: false, current_path: "/workspace"}] =
             panes["devide_b_u-2"]
  end

  describe "facade delegates through TmuxCtl.Client" do
    alias TmuxCtl.Test.FakeState

    @session "devide_alpha_u-dev"

    setup do
      previous = %{
        runner: Application.get_env(:tmux_ctl, :runner),
        fake_tmux_windows: FakeState.get(:fake_tmux_windows),
        fake_tmux_panes: FakeState.get(:fake_tmux_panes),
        fake_tmux_runner_pid: FakeState.get(:fake_tmux_runner_pid),
        fake_tmux_apply_defaults_code: FakeState.get(:fake_tmux_apply_defaults_code),
        fake_tmux_capture_output: FakeState.get(:fake_tmux_capture_output),
        fake_tmux_list_windows_all: FakeState.get(:fake_tmux_list_windows_all),
        fake_tmux_list_sessions: FakeState.get(:fake_tmux_list_sessions),
        fake_tmux_list_panes_all: FakeState.get(:fake_tmux_list_panes_all)
      }

      Application.put_env(:tmux_ctl, :runner, TmuxCtl.Test.FakeRunner)
      FakeState.put(:fake_tmux_runner_pid, self())
      put_topology!(@session)

      on_exit(fn ->
        FakeState.restore(:fake_tmux_windows, previous.fake_tmux_windows)
        FakeState.restore(:fake_tmux_panes, previous.fake_tmux_panes)
        FakeState.restore(:fake_tmux_runner_pid, previous.fake_tmux_runner_pid)

        FakeState.restore(
          :fake_tmux_apply_defaults_code,
          previous.fake_tmux_apply_defaults_code
        )

        FakeState.restore(:fake_tmux_capture_output, previous.fake_tmux_capture_output)
        FakeState.restore(:fake_tmux_list_windows_all, previous.fake_tmux_list_windows_all)
        FakeState.restore(:fake_tmux_list_sessions, previous.fake_tmux_list_sessions)
        FakeState.restore(:fake_tmux_list_panes_all, previous.fake_tmux_list_panes_all)

        if previous.runner,
          do: Application.put_env(:tmux_ctl, :runner, previous.runner),
          else: Application.delete_env(:tmux_ctl, :runner)
      end)

      :ok
    end

    test "host_shell? and container_has_tmux? delegate to TmuxRunner" do
      Application.put_env(:casein, :tmux_host_shell, true)
      assert Tmux.host_shell?()
      assert is_boolean(Tmux.container_has_tmux?(System.tmp_dir!()))
    end

    test "workspace_session_prefix builds a managed prefix" do
      assert Tmux.workspace_session_prefix("alpha") =~ "devide_alpha_"
    end

    test "session lifecycle and listing helpers delegate to the client" do
      assert :ok = Tmux.ensure_session(@session, "/workspace")
      assert {:ok, _port} = Tmux.attach(@session)
      assert {"", 0} = Tmux.send_keys(@session, "Enter")
      assert {"", 0} = Tmux.send_keys(@session, "ls", target: "%1")
      assert :ok = Tmux.send_command(@session, "mix test")
      assert :ok = Tmux.set_environment(@session, "FOO", "bar")
      assert :ok = Tmux.set_environments(@session, %{"BAR" => "baz"})
      assert :ok = Tmux.apply_defaults(@session)
      assert is_boolean(Tmux.session_exists?(@session))
      assert Tmux.session_alive?(@session) == Tmux.session_exists?(@session)
      assert [] = Tmux.list_windows()
      assert [] = Tmux.list_sessions()
      assert [] = Tmux.list_panes()
    end

    test "topology helpers read fake runner output" do
      assert [%{id: "@1", name: "shell"} | _] = Tmux.list_session_windows(@session)
      assert [%{id: "%1", current_path: "/workspace"} | _] = Tmux.list_session_panes(@session)

      assert {windows, panes} = Tmux.session_topology(@session)
      assert [%{id: "@1"} | _] = windows
      assert [%{id: "%1"} | _] = panes
    end

    test "window and pane mutations delegate to the client" do
      assert {:ok, _} = Tmux.new_window(@session, name: "agent", cwd: "/workspace")
      assert :ok = Tmux.select_window(@session, "@1")
      assert :ok = Tmux.last_window(@session)
      assert :ok = Tmux.cycle_window(@session, "next")
      assert :ok = Tmux.rename_window(@session, "@1", "shell")
      assert :ok = Tmux.set_session_alias(@session, "main")
      assert :ok = Tmux.select_pane(@session, "%1")
      assert :ok = Tmux.navigate_pane(@session, "D")
      assert :ok = Tmux.zoom_pane(@session, "%1")
      assert :ok = Tmux.ensure_zoomed(@session, "%1", true)
      assert :ok = Tmux.select_layout(@session, "tiled")
      assert :ok = Tmux.next_layout(@session)
      assert :ok = Tmux.resize_window(@session, 120, 40)
      assert :ok = Tmux.resize_pane(@session, "%1", "right", 8)
      assert {:ok, _} = Tmux.split_pane(@session, "%1", "h", cwd: "/workspace")
      assert :ok = Tmux.kill_other_panes(@session, "%1")
      assert :ok = Tmux.kill_pane(@session, "%2")
      assert :ok = Tmux.kill_window(@session, "@2")
      assert {"", 0} = Tmux.kill(@session)
    end

    test "consolidate_sessions delegates source window moves" do
      source = "devide_alpha_agent"

      FakeState.update(:fake_tmux_windows, %{}, fn windows ->
        Map.put(windows, source, [
          %{
            id: "@2",
            index: 0,
            name: "agent",
            active: true,
            panes: 1,
            activity: 0,
            current_command: "bash"
          }
        ])
      end)

      assert {:ok, %{moved_windows: 1, source_sessions: 1}} =
               Tmux.consolidate_sessions(@session, [source])
    end

    test "capture_scrollback tails output through the facade" do
      FakeState.put(:fake_tmux_capture_output, "one\ntwo\nthree")
      assert "two\nthree" = Tmux.capture_scrollback(@session, lines: 2, ansi: false)
    end

    defp put_topology!(session) do
      FakeState.put(:fake_tmux_windows, %{
        session => [
          %{
            id: "@1",
            index: 0,
            name: "shell",
            active: true,
            panes: 2,
            activity: 0,
            current_command: "bash"
          },
          %{
            id: "@2",
            index: 1,
            name: "agent",
            active: false,
            panes: 1,
            activity: 0,
            current_command: "bash"
          }
        ]
      })

      FakeState.put(:fake_tmux_panes, %{
        session => [
          %{
            id: "%1",
            window_id: "@1",
            index: 0,
            active: true,
            left: 0,
            top: 0,
            width: 120,
            height: 40,
            current_command: "bash",
            current_path: "/workspace",
            activity: 10,
            activity_flag: true,
            bell: false,
            unseen_changes: true,
            zoomed?: true
          },
          %{
            id: "%2",
            window_id: "@1",
            index: 1,
            active: false,
            left: 60,
            top: 0,
            width: 60,
            height: 40,
            current_command: "bash",
            current_path: "/workspace/apps",
            activity: 0,
            activity_flag: false,
            bell: false,
            unseen_changes: false,
            zoomed?: false
          }
        ]
      })
    end
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

  defp put_or_delete_app_env(key, nil), do: Application.delete_env(:casein, key)
  defp put_or_delete_app_env(key, value), do: Application.put_env(:casein, key, value)

  defp put_or_delete_tmux_ctl_env(key, nil), do: Application.delete_env(:tmux_ctl, key)
  defp put_or_delete_tmux_ctl_env(key, value), do: Application.put_env(:tmux_ctl, key, value)
end
