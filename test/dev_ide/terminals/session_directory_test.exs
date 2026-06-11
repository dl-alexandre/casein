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

    test "keeps executions and shells with the same id apart" do
      shell = SessionInfo.new_shell("ws", "x")
      exec = SessionInfo.new_execution("x", "tmux-x", workspace_id: "ws")

      assert length(Compose.compose([shell], [exec])) == 2
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

    test "keeps executions regardless of the viewer sid" do
      exec = SessionInfo.new_execution("e1", "tmux-e1", workspace_id: "ws")

      assert Compose.visible_for([exec], "u-alice-aaaa1111") == [exec]
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
  end
end

defmodule DevIDE.Terminals.SessionDirectoryTest do
  use ExUnit.Case, async: false

  alias DevIDE.Terminals.SessionDirectory

  setup do
    prev_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_windows = Application.get_env(:dev_ide, :fake_tmux_windows)
    prev_panes = Application.get_env(:dev_ide, :fake_tmux_panes)
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

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)

  defp put_fake_session(tmux_session, current_path \\ nil) do
    windows = Application.get_env(:dev_ide, :fake_tmux_windows, %{})

    Application.put_env(
      :dev_ide,
      :fake_tmux_windows,
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
    )

    if is_binary(current_path) do
      panes = Application.get_env(:dev_ide, :fake_tmux_panes, %{})

      Application.put_env(
        :dev_ide,
        :fake_tmux_panes,
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
      )
    end
  end

  defp drop_fake_session(tmux_session) do
    windows = Application.get_env(:dev_ide, :fake_tmux_windows, %{})
    Application.put_env(:dev_ide, :fake_tmux_windows, Map.delete(windows, tmux_session))
  end

  test "read composes scanned tmux sessions for the workspace" do
    ws = "wsdir-#{System.unique_integer([:positive])}"
    put_fake_session("devide_#{ws}_u-alice")

    assert [%{sid: "u-alice", kind: :shell}] = SessionDirectory.read(ws, workspace_name: ws)
  end

  test "read enriches scanned tmux sessions with active pane cwd" do
    ws = "wsdir-#{System.unique_integer([:positive])}"
    put_fake_session("devide_#{ws}_u-alice-abc1234", "/workspace/apps/web")

    assert [%{sid: "u-alice-abc1234", metadata: %{cwd: "/workspace/apps/web"}}] =
             SessionDirectory.read(ws, workspace_name: ws)
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
