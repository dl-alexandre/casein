defmodule TmuxCtl.Topology.WatcherTest do
  use DevIDE.TestCase, async: false

  alias TmuxCtl.Test.FakeState
  alias TmuxCtl.Topology.Watcher

  @registry __MODULE__.Registry
  @supervisor __MODULE__.Supervisor
  @tag __MODULE__

  setup_all do
    start_supervised!({Registry, keys: :unique, name: @registry})
    start_supervised!({DynamicSupervisor, name: @supervisor, strategy: :one_for_one})
    :ok
  end

  setup do
    prev_windows = FakeState.get(:fake_tmux_windows)
    prev_panes = FakeState.get(:fake_tmux_panes)

    on_exit(fn ->
      FakeState.restore(:fake_tmux_windows, prev_windows)
      FakeState.restore(:fake_tmux_panes, prev_panes)
    end)

    :ok
  end

  test "snapshots and broadcasts versioned topology updates" do
    session = "watcher-#{System.unique_integer([:positive])}"
    put_fake_topology(session, "shell", "bash")

    :ok = Watcher.subscribe(session, watcher_opts())

    assert %{
             session: ^session,
             active_window_id: "@1",
             active_pane_id: "%1",
             windows: [%{name: "shell"}]
           } =
             Watcher.get(session, watcher_opts())

    put_fake_topology(session, "tests", "mix")

    assert %{windows: [%{name: "tests"}], panes: [%{current_command: "mix"}]} =
             Watcher.refresh_now(session, watcher_opts())

    assert_receive {@tag,
                    {:updated,
                     %{
                       session: ^session,
                       windows: [%{name: "tests"}],
                       panes: [%{current_command: "mix"}]
                     }}},
                   500
  end

  test "does not broadcast when only activity ticks within the same bucket" do
    session = "watcher-activity-bucket-#{System.unique_integer([:positive])}"
    put_fake_topology(session, "shell", "bash", activity: 30)

    :ok = Watcher.subscribe(session, watcher_opts())

    assert %{version: version, panes: [%{activity: 30}]} =
             Watcher.get(session, watcher_opts(enabled: false))

    # Drain any subscribe-time noise; subsequent refreshes should stay quiet
    # while activity remains in the same 15s version bucket.
    flush_updated(session)

    put_fake_topology(session, "shell", "bash", activity: 31)

    assert %{version: ^version, panes: [%{activity: 31}]} =
             Watcher.refresh_now(session, watcher_opts())

    refute_receive {@tag, {:updated, %{session: ^session}}}, 100

    put_fake_topology(session, "shell", "mix", activity: 31)

    assert %{panes: [%{current_command: "mix", activity: 31}]} =
             Watcher.refresh_now(session, watcher_opts())

    assert_receive {@tag,
                    {:updated,
                     %{
                       session: ^session,
                       panes: [%{current_command: "mix", activity: 31}]
                     }}},
                   500
  end

  test "polling can be configured and stops when the tmux session dies" do
    session = "watcher-dead-#{System.unique_integer([:positive])}"

    FakeState.put(:fake_tmux_windows, %{})
    FakeState.put(:fake_tmux_panes, %{})

    :ok = Watcher.subscribe(session, watcher_opts())

    assert {:ok, pid} =
             Watcher.ensure_started(
               session,
               watcher_opts(refresh_ms: 10, enabled: false)
             )

    ref = Process.monitor(pid)

    refute_receive {@tag, {:session_terminated, %{session: ^session}}}, 50
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 50

    assert :ok = Watcher.configure(session, watcher_opts(refresh_ms: 10, enabled: true))

    assert_receive {@tag,
                    {:session_terminated, %{session: ^session, reason: :session_not_alive}}},
                   500

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
  end

  test "generation is stable across refreshes and changes across watcher restarts" do
    session = "watcher-gen-#{System.unique_integer([:positive])}"
    put_fake_window(session, "shell")

    assert {:ok, pid} = Watcher.ensure_started(session, watcher_opts(enabled: false))

    t1 = Watcher.get(session, watcher_opts())
    assert is_integer(t1.generation)

    put_fake_window(session, "tests")
    t2 = Watcher.refresh_now(session, watcher_opts())
    assert t2.generation == t1.generation

    ref = Process.monitor(pid)
    GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    await_unregistered(session)

    assert {:ok, pid2} = Watcher.ensure_started(session, watcher_opts(enabled: false))
    assert pid2 != pid

    t3 = Watcher.get(session, watcher_opts())
    assert is_integer(t3.generation)
    assert t3.generation != t1.generation
  end

  test "switch_subscription moves the caller between session topics" do
    s1 = "watcher-switch-a-#{System.unique_integer([:positive])}"
    s2 = "watcher-switch-b-#{System.unique_integer([:positive])}"
    put_fake_window(s1, "shell")
    put_fake_window(s2, "shell")

    assert {:ok, %{session: ^s1, generation: g1}} =
             Watcher.switch_subscription(nil, s1, watcher_opts(read: :get, enabled: false))

    assert is_integer(g1)

    put_fake_window(s1, "tests")
    _ = Watcher.refresh_now(s1, watcher_opts())
    assert_receive {@tag, {:updated, %{session: ^s1}}}, 500

    assert {:ok, %{session: ^s2, generation: g2}} =
             Watcher.switch_subscription(s1, s2, watcher_opts(enabled: false))

    assert is_integer(g2)

    put_fake_window(s1, "more")
    _ = Watcher.refresh_now(s1, watcher_opts())
    refute_receive {@tag, {:updated, %{session: ^s1}}}, 100

    put_fake_window(s2, "tests")
    _ = Watcher.refresh_now(s2, watcher_opts())
    assert_receive {@tag, {:updated, %{session: ^s2}}}, 500
  end

  test "explicit PubSub option works when application config is absent" do
    previous = Application.get_env(:tmux_ctl, :pubsub)
    Application.delete_env(:tmux_ctl, :pubsub)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tmux_ctl, :pubsub, previous),
        else: Application.delete_env(:tmux_ctl, :pubsub)
    end)

    session = "watcher-explicit-pubsub-#{System.unique_integer([:positive])}"
    put_fake_window(session, "shell")

    assert :ok = Watcher.subscribe(session, watcher_opts())

    assert {:ok, %{session: ^session}} =
             Watcher.switch_subscription(nil, session, watcher_opts(enabled: false))
  end

  test "stops after idle grace when nobody watches" do
    session = "watcher-idle-#{System.unique_integer([:positive])}"
    put_fake_window(session, "shell")

    :ok = Watcher.subscribe(session, watcher_opts())

    assert {:ok, pid} =
             Watcher.ensure_started(session, watcher_opts(enabled: false, idle_stop_ms: 50))

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    refute_receive {@tag, {:session_terminated, %{session: ^session}}}, 50
  end

  defp watcher_opts(overrides \\ []) do
    [
      registry: @registry,
      supervisor: @supervisor,
      pubsub: DevIDE.PubSub,
      tmux_resolver: fn -> TmuxCtl.Test.FakeAdapter end,
      broadcast_tag: @tag,
      refresh_ms: 60_000
    ]
    |> Keyword.merge(overrides)
  end

  defp put_fake_window(session, name, activity \\ 0) do
    FakeState.update(:fake_tmux_windows, %{}, fn windows ->
      Map.put(windows, session, [
        %{
          id: "@1",
          index: 0,
          name: name,
          active: true,
          panes: 1,
          activity: activity,
          current_command: "bash"
        }
      ])
    end)
  end

  defp put_fake_topology(session, window_name, command, opts \\ []) do
    activity = Keyword.get(opts, :activity, 10)
    put_fake_window(session, window_name, activity)

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
          current_command: command,
          current_path: "/workspace",
          activity: activity,
          activity_flag: true,
          bell: false,
          unseen_changes: true
        }
      ]
    })
  end

  defp flush_updated(session) do
    receive do
      {@tag, {:updated, %{session: ^session}}} -> flush_updated(session)
    after
      0 -> :ok
    end
  end

  defp await_unregistered(session, attempts \\ 50) do
    case Registry.lookup(@registry, session) do
      [] ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(10)
        await_unregistered(session, attempts - 1)

      _ ->
        flunk("topology watcher for #{session} never unregistered")
    end
  end
end
