defmodule Casein.Terminals.SessionDirectoryExtraTest do
  use Casein.TestCase, async: false

  alias Casein.Terminals.Session.Info, as: SessionInfo
  alias Casein.Terminals.SessionDirectory
  alias Casein.Runtimes.WorktreeReconciler
  alias Casein.Test.RuntimeSeed
  alias Casein.Workspace
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter

  setup do
    MemoryAdapter.clear()
    Casein.Runtimes.clear()
    WorktreeReconciler.clear()

    prev_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
    prev_poll = Application.get_env(:dev_ide, :session_directory_poll_ms)

    Application.put_env(:dev_ide, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    Application.put_env(:dev_ide, :session_directory_poll_ms, 25)

    on_exit(fn ->
      MemoryAdapter.clear()
      Casein.Runtimes.clear()
      WorktreeReconciler.clear()
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

  # ── read/2 with injected inventory (drives enrich_tabs purely) ──────────

  describe "read/2 with explicit :tmux_sessions and :directory_inventory" do
    test "uses injected raw tmux sessions and inventory, no adapter calls" do
      ws = "wsx-#{System.unique_integer([:positive])}"
      tmux = "devide_#{ws}_u-alice"

      raw = [%{session: tmux, activity: 7, attached: true}]

      inventory =
        {:ok,
         %{
           windows: %{
             tmux => [
               %{id: "@1", index: 0, name: "shell", active: true, activity: 0}
             ]
           },
           panes: %{
             tmux => [
               %{id: "%1", window_id: "@1", active: true, current_path: "/tmp/cwd-x"}
             ]
           }
         }}

      [tab] =
        SessionDirectory.read(ws,
          workspace_name: ws,
          tmux_sessions: raw,
          directory_inventory: inventory
        )

      assert tab.sid == "u-alice"
      assert tab.tmux_session == tmux
      # scanned metadata carried through
      assert tab.metadata.activity == 7
      assert tab.metadata.attached == true
      # cwd enrichment from injected panes
      assert tab.metadata.cwd == "/tmp/cwd-x"
      # window summary built from injected windows
      assert [%{id: "@1", index: 0, name: "shell", active: true, quiet: false}] =
               tab.metadata.windows

      assert tab.metadata.window_activity == %{"@1" => 0}
      # window→pane membership grouping
      assert tab.metadata.window_panes == %{"@1" => ["%1"]}
    end

    test "groups multiple panes under one window in order and skips blank ids" do
      ws = "wsx-#{System.unique_integer([:positive])}"
      tmux = "devide_#{ws}_u-alice"

      inventory =
        {:ok,
         %{
           windows: %{
             tmux => [%{id: "@1", index: 0, name: "shell", active: true, activity: 0}]
           },
           panes: %{
             tmux => [
               %{id: "%1", window_id: "@1", active: false, current_path: "/a"},
               %{id: "%2", window_id: "@1", active: true, current_path: "/b"},
               # blank window_id is dropped from grouping
               %{id: "%3", window_id: "", active: false, current_path: "/c"},
               # blank pane id is dropped from grouping
               %{id: "", window_id: "@1", active: false, current_path: "/d"}
             ]
           }
         }}

      [tab] =
        SessionDirectory.read(ws,
          workspace_name: ws,
          tmux_sessions: [%{session: tmux}],
          directory_inventory: inventory
        )

      # reversed back to insertion order; blanks excluded
      assert tab.metadata.window_panes == %{"@1" => ["%1", "%2"]}
      # active pane (%2) wins for cwd
      assert tab.metadata.cwd == "/b"
    end

    test "string-keyed window/pane maps are read via the string fallbacks" do
      ws = "wsx-#{System.unique_integer([:positive])}"
      tmux = "devide_#{ws}_u-alice"

      inventory =
        {:ok,
         %{
           windows: %{
             tmux => [
               %{"id" => "@9", "index" => 2, "name" => "agent", "active" => "1", "activity" => 0}
             ]
           },
           panes: %{
             tmux => [
               %{"id" => "%9", "window_id" => "@9", "active" => "1", "current_path" => "/srv"}
             ]
           }
         }}

      [tab] =
        SessionDirectory.read(ws,
          workspace_name: ws,
          tmux_sessions: [%{session: tmux}],
          directory_inventory: inventory
        )

      assert [%{id: "@9", index: 2, name: "agent", active: true, quiet: _}] = tab.metadata.windows
      assert tab.metadata.window_panes == %{"@9" => ["%9"]}
      assert tab.metadata.cwd == "/srv"
    end

    test "stores title-derived agent state in window and pane summaries" do
      ws = "wsx-#{System.unique_integer([:positive])}"
      tmux = "devide_#{ws}_u-alice"
      title = <<0x2733::utf8>> <> " Review agent state"
      now = DateTime.utc_now() |> DateTime.to_unix()

      inventory =
        {:ok,
         %{
           windows: %{
             tmux => [
               %{id: "@1", index: 0, name: "claude", active: true, activity: 0}
             ]
           },
           panes: %{
             tmux => [
               %{
                 id: "%1",
                 window_id: "@1",
                 active: true,
                 role: "agent",
                 current_command: "node",
                 current_path: "/srv",
                 activity: now,
                 pane_title: title
               }
             ]
           }
         }}

      [tab] =
        SessionDirectory.read(ws,
          workspace_name: ws,
          tmux_sessions: [%{session: tmux}],
          directory_inventory: inventory
        )

      assert [
               %{
                 id: "@1",
                 name: "claude",
                 quiet: true,
                 pane_state: :ready,
                 task_summary: "Review agent state"
               }
             ] = tab.metadata.windows

      assert [
               %{
                 id: "%1",
                 role: "agent",
                 current_command: "node",
                 pane_state: :ready,
                 task_summary: "Review agent state"
               }
             ] = tab.metadata.pane_summaries
    end

    test "falls back to per-session adapter reads when inventory is :error" do
      ws = "wsx-#{System.unique_integer([:positive])}"
      tmux = "devide_#{ws}_u-alice"
      put_fake_session(tmux, "/fallback/cwd")

      [tab] =
        SessionDirectory.read(ws,
          workspace_name: ws,
          tmux_sessions: [%{session: tmux}],
          directory_inventory: :error
        )

      # fallback_windows/fallback_panes path: list_session_windows/panes hit the adapter
      assert tab.metadata.cwd == "/fallback/cwd"
      assert [%{id: "@1", name: "shell", active: true}] = tab.metadata.windows
      assert tab.metadata.window_panes == %{"@1" => ["%1"]}
    end

    test "blank current_path leaves cwd unset and windows empty when none reported" do
      ws = "wsx-#{System.unique_integer([:positive])}"
      tmux = "devide_#{ws}_u-alice"

      inventory =
        {:ok,
         %{
           # no windows reported for this session -> put_session_windows no-op
           windows: %{},
           panes: %{
             tmux => [%{id: "%1", window_id: "@1", active: true, current_path: "   "}]
           }
         }}

      [tab] =
        SessionDirectory.read(ws,
          workspace_name: ws,
          tmux_sessions: [%{session: tmux}],
          directory_inventory: inventory
        )

      # blank_to_nil trims "   " to nil -> no :cwd key added
      refute Map.has_key?(tab.metadata, :cwd)
      # empty windows list -> put_session_windows fallback clause leaves metadata
      refute Map.has_key?(tab.metadata, :windows)
      # but window_panes is still computed (pane has window_id "@1")
      assert tab.metadata.window_panes == %{"@1" => ["%1"]}
    end

    test "session with no tmux_session match yields an empty tab list" do
      ws = "wsx-#{System.unique_integer([:positive])}"

      assert [] =
               SessionDirectory.read(ws,
                 workspace_name: ws,
                 tmux_sessions: ["totally-unrelated-session"],
                 directory_inventory: :error
               )
    end

    test "picks first pane with a path when no pane is marked active" do
      ws = "wsx-#{System.unique_integer([:positive])}"
      tmux = "devide_#{ws}_u-alice"

      inventory =
        {:ok,
         %{
           windows: %{},
           panes: %{
             tmux => [
               %{id: "%1", window_id: "@1", active: false, current_path: nil},
               %{id: "%2", window_id: "@1", active: false, current_path: "/second"}
             ]
           }
         }}

      [tab] =
        SessionDirectory.read(ws,
          workspace_name: ws,
          tmux_sessions: [%{session: tmux}],
          directory_inventory: inventory
        )

      assert tab.metadata.cwd == "/second"
    end
  end

  # ── agent_worktree_tabs (seeded runtime → synthesized shell tab) ────────

  describe "read/2 agent worktree enrichment" do
    test "synthesizes a worktree shell tab and falls git_toplevel back to path" do
      ws = "wsx-#{System.unique_integer([:positive])}"
      name = "alpha-#{System.unique_integer([:positive])}"
      tmux_session = Casein.Terminals.Tmux.session_name(name, "wt-min")
      path = Path.join(System.tmp_dir!(), "devide-wt-#{System.unique_integer([:positive])}")

      _ =
        State.sync(%Workspace{
          id: ws,
          name: name,
          status: :running,
          path: System.tmp_dir!(),
          metadata: %{}
        })

      {:ok, _runtime} =
        RuntimeSeed.seed_runtime(ws,
          runtime_id: "wt-min",
          host_id: "local",
          branch: "min-branch",
          status: "provisioned",
          tmux_session_id: tmux_session,
          worktree_path: path,
          metadata: %{
            "kind" => "agent_worktree",
            "provisioning_model" => "agent_worktree",
            "git_worktree" => true,
            "worktree_path" => path
          }
        )

      [tab] =
        SessionDirectory.read(ws,
          workspace_name: name,
          # no scanned sessions; tab comes solely from agent_worktree_tabs
          tmux_sessions: [],
          # the worktree path is not a real pane cwd here, so enrichment is a
          # no-op and the synthesized metadata survives unchanged
          directory_inventory: {:ok, %{windows: %{}, panes: %{}}}
        )

      assert tab.sid == "wt-min"
      assert tab.tmux_session == tmux_session
      assert tab.metadata.git_worktree? == true
      # git_toplevel || path fallback when no explicit git_toplevel reported
      assert tab.metadata.git_toplevel == path
      assert tab.metadata.worktree_path == path
      assert tab.metadata.runtime_id == "wt-min"
    end
  end

  # ── fetch/tabs fallback paths ───────────────────────────────────────────

  describe "fetch/3" do
    test "returns :error when the attach id is absent" do
      ws = "wsx-#{System.unique_integer([:positive])}"
      put_fake_session("devide_#{ws}_u-alice")

      assert :error = SessionDirectory.fetch(ws, "ghost", workspace_name: ws)
    end
  end

  # ── refresh/1 no-op and live cast paths ─────────────────────────────────

  describe "refresh/1" do
    test "is a no-op when no directory is running for the workspace" do
      ws = "wsx-no-dir-#{System.unique_integer([:positive])}"

      assert :ok = SessionDirectory.refresh(ws)
    end

    test "pokes a running directory" do
      ws = "wsx-#{System.unique_integer([:positive])}"
      put_fake_session("devide_#{ws}_u-alice")

      assert {:ok, pid} = SessionDirectory.ensure_started(ws, workspace_name: ws)
      :sys.get_state(pid)

      assert :ok = SessionDirectory.refresh(ws)
      # the cast is handled without crashing the server
      assert is_map(:sys.get_state(pid))
    end
  end

  describe "refresh_worktrees/1" do
    test "reconciles then refreshes (no-op directory) and returns :ok" do
      ws = "wsx-wt-#{System.unique_integer([:positive])}"

      assert :ok = SessionDirectory.refresh_worktrees(ws)
    end
  end

  # ── topic/1 and ensure_started idempotency ──────────────────────────────

  describe "topic/1" do
    test "prefixes the workspace id" do
      assert SessionDirectory.topic("ws-42") == "terminal_tabs:ws-42"
    end
  end

  describe "ensure_started/2" do
    test "returns the same pid on a second call (already_started path)" do
      ws = "wsx-#{System.unique_integer([:positive])}"
      put_fake_session("devide_#{ws}_u-alice")

      assert {:ok, pid} = SessionDirectory.ensure_started(ws, workspace_name: ws)
      assert {:ok, ^pid} = SessionDirectory.ensure_started(ws, workspace_name: ws)
    end
  end

  # ── subscribe/2 idempotency (duplicate watch is ignored) ────────────────

  describe "subscribe/2" do
    test "double subscribe keeps a single watcher and broadcasts once on change" do
      ws = "wsx-#{System.unique_integer([:positive])}"
      put_fake_session("devide_#{ws}_u-alice")

      assert :ok = SessionDirectory.subscribe(ws, workspace_name: ws)
      assert :ok = SessionDirectory.subscribe(ws, workspace_name: ws)

      assert {:ok, pid} = SessionDirectory.ensure_started(ws, workspace_name: ws)
      state = :sys.get_state(pid)
      assert map_size(state.watchers) == 1

      put_fake_session("devide_#{ws}_u-bob")

      assert_receive {SessionDirectory, {:sessions_updated, ^ws, tabs}}, 1_000
      assert tabs |> Enum.map(& &1.sid) |> Enum.sort() == ["u-alice", "u-bob"]
    end
  end

  # ── directory_inventory/1 explicit-opt passthrough ──────────────────────

  describe "directory_inventory/1" do
    test "returns the inventory provided in opts verbatim" do
      inv = {:ok, %{windows: %{}, panes: %{}}}
      assert SessionDirectory.directory_inventory(directory_inventory: inv) == inv
    end

    test "falls back to the configured adapter when not provided" do
      # FakeTmuxAdapter exports directory_inventory/0
      assert {:ok, %{windows: _, panes: _}} = SessionDirectory.directory_inventory([])
    end
  end

  # ── list_tmux_sessions/0 adapter resolution ─────────────────────────────

  describe "list_tmux_sessions/0" do
    test "delegates to the configured adapter" do
      ws = "wsx-#{System.unique_integer([:positive])}"
      tmux = "devide_#{ws}_u-alice"
      put_fake_session(tmux)

      sessions = SessionDirectory.list_tmux_sessions()
      assert Enum.any?(sessions, &(Map.get(&1, :session) == tmux))
    end

    test "returns [] when the adapter cannot list sessions" do
      prev = Application.get_env(:dev_ide, :tmux_adapter)
      # A module that exists but does not export list_sessions/0
      Application.put_env(:dev_ide, :tmux_adapter, Casein.Terminals.Session.Info)

      try do
        assert SessionDirectory.list_tmux_sessions() == []
      after
        Application.put_env(:dev_ide, :tmux_adapter, prev)
      end
    end
  end

  # ── workspace_names handling via read/2 (:workspace_names list opt) ──────

  describe "workspace name resolution" do
    test "accepts an explicit :workspace_names list and matches any prefix" do
      ws = "wsx-#{System.unique_integer([:positive])}"
      name = "beta-#{System.unique_integer([:positive])}"

      by_name = Casein.Terminals.Tmux.session_name(name, "u-alice")
      by_id = Casein.Terminals.Tmux.session_name(ws, "u-bob")

      sids =
        SessionDirectory.read(ws,
          workspace_names: [name, ws],
          tmux_sessions: [%{session: by_name}, %{session: by_id}],
          directory_inventory: :error
        )
        |> Enum.map(& &1.sid)
        |> Enum.sort()

      assert sids == ["u-alice", "u-bob"]
    end

    test "empty/blank names are filtered, leaving only the id prefix" do
      ws = "wsx-#{System.unique_integer([:positive])}"
      by_id = Casein.Terminals.Tmux.session_name(ws, "u-only")

      [tab] =
        SessionDirectory.read(ws,
          workspace_name: "",
          tmux_sessions: [%{session: by_id}],
          directory_inventory: :error
        )

      assert tab.sid == "u-only"
    end
  end

  # ── compose merges scanned tmux with seeded attachable registry shell ────

  describe "read/2 compose with registry attachables" do
    test "scanned tmux entry carries the live tmux session and metadata" do
      ws = "wsx-#{System.unique_integer([:positive])}"
      tmux = "devide_#{ws}_u-alice"

      [tab] =
        SessionDirectory.read(ws,
          workspace_name: ws,
          tmux_sessions: [%{session: tmux, activity: 3}],
          directory_inventory: {:ok, %{windows: %{}, panes: %{}}}
        )

      assert tab.tmux_session == tmux
      assert tab.metadata.activity == 3
      assert %SessionInfo{kind: :shell, sid: "u-alice"} = tab
    end
  end
end
