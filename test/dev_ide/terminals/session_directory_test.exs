defmodule DevIDE.Terminals.SessionDirectory.ComposeTest do
  use ExUnit.Case, async: true

  doctest DevIDE.Terminals.SessionDirectory.Compose

  alias DevIDE.Terminals.Session.Info, as: SessionInfo
  alias DevIDE.Terminals.SessionDirectory.Compose

  defp scanned_shell(workspace_id, sid, tmux_session, metadata \\ %{}) do
    SessionInfo.new_shell(workspace_id, sid, metadata: metadata)
    |> Map.put(:tmux_session, tmux_session)
  end

  describe "compose/2" do
    test "dedupes by {kind, attach_id} preferring the scanned (tmux) entry" do
      scanned = scanned_shell("ws", "u-alice", "devide_ws_u-alice", %{activity: 5})
      registry = SessionInfo.new_shell("ws", "u-alice")

      assert [tab] = Compose.compose([scanned], [registry])
      assert tab.tmux_session == "devide_ws_u-alice"
      assert tab.metadata == %{activity: 5}
    end

    test "keeps different kinds with the same id apart" do
      shell = SessionInfo.new_shell("ws", "x")
      agent = SessionInfo.new_agent("x", workspace_id: "ws")

      assert length(Compose.compose([shell], [agent])) == 2
    end
  end

  describe "scan_tmux_sessions/3" do
    test "maps only sessions with the workspace prefix and keeps metadata" do
      raw = [
        %{session: "devide_alpha_u-alice", activity: 9, attached: true},
        %{session: "devide_other_u-bob", activity: 1},
        "devide_alpha_u-carol-tabc12",
        "unrelated"
      ]

      tabs = Compose.scan_tmux_sessions(raw, "ws-alpha", "alpha")

      assert [
               %SessionInfo{sid: "u-alice", metadata: %{activity: 9, attached: true}},
               %SessionInfo{sid: "u-carol-tabc12", metadata: %{}}
             ] = tabs

      assert Enum.all?(tabs, &(&1.workspace_id == "ws-alpha"))
      assert Enum.all?(tabs, &String.starts_with?(&1.tmux_session, "devide_alpha_"))
    end

    test "maps sessions from workspace name and id aliases" do
      raw = [
        %{session: "devide_alpha_u-alice", activity: 9},
        %{session: "devide_ws-1_u-bob", activity: 8},
        %{session: "devide_other_u-carol", activity: 7}
      ]

      tabs = Compose.scan_tmux_sessions(raw, "ws-1", ["alpha", "ws-1"])

      assert Enum.map(tabs, &{&1.sid, &1.tmux_session}) == [
               {"u-alice", "devide_alpha_u-alice"},
               {"u-bob", "devide_ws-1_u-bob"}
             ]
    end
  end

  describe "visible_for/2" do
    test "hides the viewer's own default shell" do
      tabs = [scanned_shell("ws", "u-alice-aaaa1111", "t1")]

      assert Compose.visible_for(tabs, "u-alice-aaaa1111") == []
    end

    test "keeps sibling browser-tab shells from the same family" do
      mine = scanned_shell("ws", "u-alice-aaaa1111", "t1")
      sibling = scanned_shell("ws", "u-alice-bbbb2222", "t2")
      other_user = scanned_shell("ws", "u-bob-cccc3333", "t3")
      explicit = scanned_shell("ws", "u-alice", "t4")

      visible = Compose.visible_for([mine, sibling, other_user, explicit], "u-alice-aaaa1111")

      assert Enum.map(visible, & &1.sid) == [
               "u-alice-bbbb2222",
               "u-bob-cccc3333",
               "u-alice"
             ]
    end

    test "keeps non-shell sessions regardless of the viewer sid" do
      agent = SessionInfo.new_agent("e1", workspace_id: "ws")

      assert Compose.visible_for([agent], "u-alice-aaaa1111") == [agent]
    end

    test "filters nothing when the viewer has no per-tab sid family" do
      sibling = scanned_shell("ws", "u-alice-bbbb2222", "t2")

      assert Compose.visible_for([sibling], "u-alice") == [sibling]
    end
  end

  describe "stable_hash/1" do
    test "ignores volatile activity metadata but tracks membership and order-independence" do
      t1 = scanned_shell("ws", "u-a", "s1", %{activity: 1})
      t1_later = scanned_shell("ws", "u-a", "s1", %{activity: 999})
      t2 = scanned_shell("ws", "u-b", "s2")

      assert Compose.stable_hash([t1]) == Compose.stable_hash([t1_later])
      assert Compose.stable_hash([t1, t2]) == Compose.stable_hash([t2, t1])
      refute Compose.stable_hash([t1]) == Compose.stable_hash([t1, t2])
    end

    test "tracks cwd metadata changes" do
      t1 = scanned_shell("ws", "u-a", "s1", %{cwd: "/workspace"})
      t1_moved = scanned_shell("ws", "u-a", "s1", %{cwd: "/workspace/apps/web"})

      refute Compose.stable_hash([t1]) == Compose.stable_hash([t1_moved])
    end

    test "tracks git context metadata changes" do
      t1 = scanned_shell("ws", "u-a", "s1", %{cwd: "/workspace", git_branch: "main"})
      t1_branch = scanned_shell("ws", "u-a", "s1", %{cwd: "/workspace", git_branch: "feature"})

      refute Compose.stable_hash([t1]) == Compose.stable_hash([t1_branch])
    end

    test "tracks window summary metadata changes" do
      shell = %{id: "@1", index: 0, name: "shell", active: true}
      tests = %{id: "@2", index: 1, name: "tests", active: false}

      t1 = scanned_shell("ws", "u-a", "s1", %{windows: [shell]})
      t1_same = scanned_shell("ws", "u-a", "s1", %{windows: [shell]})
      t1_grown = scanned_shell("ws", "u-a", "s1", %{windows: [shell, tests]})

      assert Compose.stable_hash([t1]) == Compose.stable_hash([t1_same])
      refute Compose.stable_hash([t1]) == Compose.stable_hash([t1_grown])
    end
  end
end

defmodule DevIDE.Terminals.SessionDirectoryTest do
  use ExUnit.Case, async: false

  alias DevIDE.Terminals.Session.Info, as: SessionInfo
  alias DevIDE.Terminals.SessionDirectory
  alias DevIdeWeb.WorkspaceLive.Show.TerminalState

  setup do
    prev_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
    prev_poll = Application.get_env(:dev_ide, :session_directory_poll_ms)

    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    Application.put_env(:dev_ide, :session_directory_poll_ms, 25)

    on_exit(fn ->
      restore(:tmux_adapter, prev_adapter)
      restore(:fake_tmux_windows, prev_windows)
      restore(:fake_tmux_panes, prev_panes)
      restore(:session_directory_poll_ms, prev_poll)
    end)

    :ok
  end

  @fake_state_keys ~w(fake_tmux_windows fake_tmux_panes)a

  defp restore(key, value) when key in @fake_state_keys,
    do: TmuxCtl.Test.FakeState.restore(key, value)

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)

  defp put_fake_session(tmux_session, current_path \\ nil) do
    TmuxCtl.Test.FakeState.update(:fake_tmux_windows, %{}, fn windows ->
      Map.put(windows, tmux_session, [
        %{
          id: "@1",
          index: 0,
          name: "shell",
          active: true,
          panes: 1,
          activity: 0,
          current_command: "bash"
        }
      ])
    end)

    if is_binary(current_path) do
      TmuxCtl.Test.FakeState.update(:fake_tmux_panes, %{}, fn panes ->
        Map.put(panes, tmux_session, [
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
            current_path: current_path
          }
        ])
      end)
    end
  end

  defp drop_fake_session(tmux_session) do
    windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows, %{})
    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, Map.delete(windows, tmux_session))
  end

  defp git_repo! do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "devide-session-directory-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    git!(tmp, ["init", "--initial-branch=main"])
    git!(tmp, ["config", "user.name", "Test"])
    git!(tmp, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(tmp, "README.md"), "# Test Repo\n")
    git!(tmp, ["add", "README.md"])
    git!(tmp, ["commit", "-m", "init"])

    on_exit(fn -> File.rm_rf!(tmp) end)

    tmp
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    String.trim(output)
  end

  test "read composes scanned tmux sessions for the workspace" do
    ws = "wsdir-#{System.unique_integer([:positive])}"
    put_fake_session("devide_#{ws}_u-alice")

    assert [%{sid: "u-alice", kind: :shell}] = SessionDirectory.read(ws, workspace_name: ws)
  end

  test "read keeps tmux sessions named by workspace name or stable id" do
    ws = "wsdir-#{System.unique_integer([:positive])}"
    name = "alpha-#{System.unique_integer([:positive])}"

    put_fake_session(DevIDE.Terminals.Tmux.session_name(name, "u-alice"))
    put_fake_session(DevIDE.Terminals.Tmux.session_name(ws, "u-bob"))

    sids =
      ws
      |> SessionDirectory.read(workspace_name: name)
      |> Enum.map(& &1.sid)
      |> Enum.sort()

    assert sids == ["u-alice", "u-bob"]
  end

  test "read enriches scanned tmux sessions with active pane cwd" do
    ws = "wsdir-#{System.unique_integer([:positive])}"
    put_fake_session("devide_#{ws}_u-alice-abc1234", "/workspace/apps/web")

    assert [%{sid: "u-alice-abc1234", metadata: %{cwd: "/workspace/apps/web"}}] =
             SessionDirectory.read(ws, workspace_name: ws)
  end

  test "read enriches scanned tmux sessions with window summaries" do
    ws = "wsdir-#{System.unique_integer([:positive])}"
    put_fake_session("devide_#{ws}_u-alice")

    assert [%{sid: "u-alice", metadata: %{windows: [window]} = metadata}] =
             SessionDirectory.read(ws, workspace_name: ws)

    assert window == %{id: "@1", index: 0, name: "shell", active: true, quiet: false}

    # Volatile activity lives in its own key, outside the stable-hash
    # allowlist, so the picker can show freshness without broadcast churn.
    assert metadata.window_activity == %{"@1" => 0}
  end

  test "read flags quiet agent windows in stable window metadata" do
    ws = "wsdir-#{System.unique_integer([:positive])}"
    tmux_session = "devide_#{ws}_u-alice"
    now = DateTime.utc_now() |> DateTime.to_unix()

    TmuxCtl.Test.FakeState.update(:fake_tmux_windows, %{}, fn windows ->
      Map.put(windows, tmux_session, [
        %{
          id: "@1",
          index: 0,
          name: "agent",
          active: true,
          panes: 1,
          activity: now - 120,
          current_command: "claude"
        },
        %{
          id: "@2",
          index: 1,
          name: "shell",
          active: false,
          panes: 1,
          activity: now - 120,
          current_command: "bash"
        }
      ])
    end)

    assert [%{metadata: %{windows: [agent_window, shell_window]}}] =
             SessionDirectory.read(ws, workspace_name: ws)

    # The silent agent window flips quiet; the equally silent shell does not.
    assert %{id: "@1", quiet: true} = agent_window
    assert %{id: "@2", quiet: false} = shell_window
  end

  test "resolve_active_session recovers a scanned tmux shell after registry reset" do
    ws = "wsdir-#{System.unique_integer([:positive])}"
    name = "alpha-#{System.unique_integer([:positive])}"
    sid = "u-alice"
    tmux_session = DevIDE.Terminals.Tmux.session_name(ws, sid)
    put_fake_session(tmux_session)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        workspace: %{id: ws, name: name},
        default_terminal_sid: "u-current"
      }
    }

    assert {:ok, %SessionInfo{kind: :shell, sid: ^sid}, ^tmux_session} =
             TerminalState.resolve_active_session(socket, sid, nil)
  end

  test "read enriches scanned tmux sessions with git context" do
    ws = "wsdir-#{System.unique_integer([:positive])}"
    repo = git_repo!()
    cwd = Path.join(repo, "apps/web")
    File.mkdir_p!(cwd)

    put_fake_session("devide_#{ws}_u-alice-abc1234", cwd)

    assert [%{sid: "u-alice-abc1234", metadata: metadata}] =
             SessionDirectory.read(ws, workspace_name: ws)

    assert metadata.cwd == cwd
    assert metadata.git_toplevel == repo
    assert metadata.git_branch == "main"
    assert metadata.git_worktree? == false
    assert metadata.git_detached? == false
    assert is_binary(metadata.git_head_sha)
  end

  test "broadcasts sessions_updated when the tab list changes while watched" do
    ws = "wsdir-#{System.unique_integer([:positive])}"
    s1 = "devide_#{ws}_u-alice"
    put_fake_session(s1)

    assert :ok = SessionDirectory.subscribe(ws, workspace_name: ws)
    assert [%{sid: "u-alice"}] = SessionDirectory.tabs(ws, workspace_name: ws)

    s2 = "devide_#{ws}_u-bob"
    put_fake_session(s2)

    assert_receive {SessionDirectory, {:sessions_updated, ^ws, tabs}}, 1_000
    assert Enum.map(tabs, & &1.sid) |> Enum.sort() == ["u-alice", "u-bob"]

    drop_fake_session(s2)

    assert_receive {SessionDirectory, {:sessions_updated, ^ws, tabs}}, 1_000
    assert Enum.map(tabs, & &1.sid) == ["u-alice"]
  end

  test "does not broadcast when only volatile activity changes" do
    ws = "wsdir-#{System.unique_integer([:positive])}"
    s1 = "devide_#{ws}_u-alice"
    put_fake_session(s1)

    assert :ok = SessionDirectory.subscribe(ws, workspace_name: ws)
    _ = SessionDirectory.tabs(ws, workspace_name: ws)

    refute_receive {SessionDirectory, {:sessions_updated, ^ws, _tabs}}, 200
  end

  test "refresh_now returns fresh tabs synchronously" do
    ws = "wsdir-#{System.unique_integer([:positive])}"
    put_fake_session("devide_#{ws}_u-alice")

    assert [%{sid: "u-alice"}] = SessionDirectory.refresh_now(ws, workspace_name: ws)

    put_fake_session("devide_#{ws}_u-bob")

    sids =
      SessionDirectory.refresh_now(ws, workspace_name: ws) |> Enum.map(& &1.sid) |> Enum.sort()

    assert sids == ["u-alice", "u-bob"]
  end

  test "directory stops when its last watcher goes away" do
    ws = "wsdir-#{System.unique_integer([:positive])}"
    put_fake_session("devide_#{ws}_u-alice")

    watcher =
      spawn(fn ->
        :ok = SessionDirectory.subscribe(ws, workspace_name: ws)

        receive do
          :release -> :ok
        end
      end)

    # Wait for the watch cast to land.
    Process.sleep(50)
    assert {:ok, pid} = SessionDirectory.ensure_started(ws, workspace_name: ws)
    monitor = Process.monitor(pid)

    send(watcher, :release)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
  end

  test "fetch finds tabs by attach id" do
    ws = "wsdir-#{System.unique_integer([:positive])}"
    put_fake_session("devide_#{ws}_u-alice")

    assert {:ok, %{sid: "u-alice"}} =
             SessionDirectory.fetch(ws, "u-alice", workspace_name: ws)

    assert :error = SessionDirectory.fetch(ws, "nope", workspace_name: ws)
  end
end
