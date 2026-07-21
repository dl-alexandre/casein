defmodule TmuxCtl.Topology.WatcherEventsTest do
  @moduledoc """
  Event-source path for Topology.Watcher — FakeEventSource driven, no real tmux.
  """

  use DevIDE.TestCase, async: false

  alias TmuxCtl.Test.FakeEventSource
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

    {:ok, fake} = start_supervised(FakeEventSource)

    on_exit(fn ->
      FakeState.restore(:fake_tmux_windows, prev_windows)
      FakeState.restore(:fake_tmux_panes, prev_panes)
    end)

    %{fake: fake}
  end

  test "event triggers an updated broadcast with poll-identical snapshot content", %{fake: fake} do
    session = "wevt-#{System.unique_integer([:positive])}"
    put_fake_topology(session, "shell", "bash")

    :ok = Watcher.subscribe(session, watcher_opts(fake))

    assert {:ok, _pid} =
             Watcher.ensure_started(
               session,
               watcher_opts(fake, enabled: true, refresh_ms: 200, reconcile_ms: 60_000)
             )

    flush_updated(session)

    put_fake_topology(session, "tests", "mix")

    FakeEventSource.emit(fake, %{
      type: :window_renamed,
      window_id: "@1",
      raw: "%window-renamed @1 tests"
    })

    assert_receive {@tag,
                    {:updated,
                     %{
                       session: ^session,
                       windows: [%{name: "tests"}],
                       panes: [%{current_command: "mix"}]
                     }}},
                   1_000
  end

  test "coalesces events within min_interval into one snapshot", %{fake: fake} do
    session = "wevt-coal-#{System.unique_integer([:positive])}"
    put_fake_topology(session, "shell", "bash")

    counter = :counters.new(1, [:atomics])

    resolver = fn ->
      :counters.add(counter, 1, 1)
      TmuxCtl.Test.FakeAdapter
    end

    min_interval = 200

    assert {:ok, _pid} =
             Watcher.ensure_started(
               session,
               watcher_opts(fake,
                 enabled: true,
                 refresh_ms: min_interval,
                 reconcile_ms: 60_000,
                 tmux_resolver: resolver
               )
             )

    # Init took one snapshot via resolver.
    init_calls = :counters.get(counter, 1)
    assert init_calls >= 1

    :ok = Watcher.subscribe(session, watcher_opts(fake))
    flush_updated(session)

    put_fake_topology(session, "a", "bash")
    FakeEventSource.emit(fake, %{type: :window_add, window_id: "@2"})
    put_fake_topology(session, "b", "bash")
    FakeEventSource.emit(fake, %{type: :window_add, window_id: "@3"})
    put_fake_topology(session, "c", "bash")
    FakeEventSource.emit(fake, %{type: :window_add, window_id: "@4"})

    # Allow coalesced refresh to fire once.
    Process.sleep(min_interval + 80)

    calls_after = :counters.get(counter, 1)
    # At most one extra snapshot beyond init for the coalesced burst.
    assert calls_after - init_calls <= 2
    assert calls_after > init_calls
  end

  test "listener_down falls back to refresh_ms polling; listener_up reconciles", %{fake: fake} do
    session = "wevt-fb-#{System.unique_integer([:positive])}"
    put_fake_topology(session, "shell", "bash")

    counter = :counters.new(1, [:atomics])

    resolver = fn ->
      :counters.add(counter, 1, 1)
      TmuxCtl.Test.FakeAdapter
    end

    assert {:ok, pid} =
             Watcher.ensure_started(
               session,
               watcher_opts(fake,
                 enabled: true,
                 refresh_ms: 50,
                 reconcile_ms: 60_000,
                 tmux_resolver: resolver
               )
             )

    # Connected event mode: no fast poll. Snapshot count stays near init.
    Process.sleep(180)
    mid = :counters.get(counter, 1)

    FakeEventSource.set_connected(fake, false)
    # Give poll fallback time to fire several times.
    Process.sleep(220)
    after_down = :counters.get(counter, 1)
    assert after_down > mid + 1

    put_fake_topology(session, "recovered", "mix")
    :ok = Watcher.subscribe(session, watcher_opts(fake))
    flush_updated(session)

    FakeEventSource.set_connected(fake, true)

    assert_receive {@tag,
                    {:updated,
                     %{
                       session: ^session,
                       windows: [%{name: "recovered"}]
                     }}},
                   1_000

    # generation stable across mode flips
    t = Watcher.get(session, watcher_opts(fake))
    assert is_integer(t.generation)
    assert Process.alive?(pid)
  end

  test "event mode + activity-only change in same 15s bucket does not broadcast", %{fake: fake} do
    session = "wevt-bucket-#{System.unique_integer([:positive])}"
    put_fake_topology(session, "shell", "bash", activity: 30)

    :ok = Watcher.subscribe(session, watcher_opts(fake))

    assert {:ok, _pid} =
             Watcher.ensure_started(
               session,
               watcher_opts(fake, enabled: true, refresh_ms: 50, reconcile_ms: 60_000)
             )

    assert %{version: version} = Watcher.get(session, watcher_opts(fake))
    flush_updated(session)

    put_fake_topology(session, "shell", "bash", activity: 31)
    FakeEventSource.emit(fake, %{type: :layout_change, window_id: "@1"})

    Process.sleep(80)
    refute_receive {@tag, {:updated, %{session: ^session}}}, 100

    assert %{version: ^version, panes: [%{activity: 31}]} =
             Watcher.get(session, watcher_opts(fake))
  end

  test "session death via reconcile with zero events still terminates", %{fake: fake} do
    session = "wevt-dead-#{System.unique_integer([:positive])}"
    put_fake_topology(session, "shell", "bash")

    :ok = Watcher.subscribe(session, watcher_opts(fake))

    assert {:ok, pid} =
             Watcher.ensure_started(
               session,
               watcher_opts(fake, enabled: true, refresh_ms: 60_000, reconcile_ms: 40)
             )

    ref = Process.monitor(pid)

    # Wipe topology; wait for reconcile timer (no events emitted).
    FakeState.put(:fake_tmux_windows, %{})
    FakeState.put(:fake_tmux_panes, %{})

    assert_receive {@tag,
                    {:session_terminated, %{session: ^session, reason: :session_not_alive}}},
                   1_000

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "generation is stable across event-mode refreshes", %{fake: fake} do
    session = "wevt-gen-#{System.unique_integer([:positive])}"
    put_fake_topology(session, "shell", "bash")

    assert {:ok, _pid} =
             Watcher.ensure_started(
               session,
               watcher_opts(fake, enabled: true, refresh_ms: 100, reconcile_ms: 60_000)
             )

    t1 = Watcher.get(session, watcher_opts(fake))
    put_fake_topology(session, "tests", "mix")
    FakeEventSource.emit(fake, %{type: :window_renamed, window_id: "@1"})
    Process.sleep(150)
    t2 = Watcher.get(session, watcher_opts(fake))

    assert t2.generation == t1.generation
    assert hd(t2.windows).name == "tests"
  end

  test "event_source nil keeps pure polling (existing path)", %{fake: _fake} do
    session = "wevt-nil-#{System.unique_integer([:positive])}"
    put_fake_topology(session, "shell", "bash")

    opts =
      [
        registry: @registry,
        supervisor: @supervisor,
        pubsub: DevIDE.PubSub,
        tmux_resolver: fn -> TmuxCtl.Test.FakeAdapter end,
        broadcast_tag: @tag,
        refresh_ms: 60_000,
        event_source: nil,
        enabled: false
      ]

    :ok = Watcher.subscribe(session, opts)
    assert %{session: ^session, windows: [%{name: "shell"}]} = Watcher.get(session, opts)

    put_fake_topology(session, "tests", "mix")
    assert %{windows: [%{name: "tests"}]} = Watcher.refresh_now(session, opts)

    assert_receive {@tag, {:updated, %{session: ^session, windows: [%{name: "tests"}]}}}, 500
  end

  # -- helpers --------------------------------------------------------------

  defp watcher_opts(fake, overrides \\ []) do
    [
      registry: @registry,
      supervisor: @supervisor,
      pubsub: DevIDE.PubSub,
      tmux_resolver: fn -> TmuxCtl.Test.FakeAdapter end,
      broadcast_tag: @tag,
      refresh_ms: 200,
      reconcile_ms: 60_000,
      event_source: {FakeEventSource, fake},
      idle_stop_ms: 60_000
    ]
    |> Keyword.merge(overrides)
  end

  defp put_fake_topology(session, window_name, command, opts \\ []) do
    activity = Keyword.get(opts, :activity, 10)

    FakeState.update(:fake_tmux_windows, %{}, fn windows ->
      Map.put(windows, session, [
        %{
          id: "@1",
          index: 0,
          name: window_name,
          active: true,
          panes: 1,
          activity: activity,
          current_command: command
        }
      ])
    end)

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
end
