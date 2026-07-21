defmodule TmuxCtl.Topology.WatcherRefreshTelemetryTest do
  @moduledoc """
  Slice 3: watcher emits refresh-source + events_absorbed telemetry.
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

    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:tmux_ctl, :topology, :watcher, :refresh],
        fn event, measurements, metadata, pid ->
          send(pid, {:watcher_refresh_telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      FakeState.restore(:fake_tmux_windows, prev_windows)
      FakeState.restore(:fake_tmux_panes, prev_panes)
    end)

    %{fake: fake}
  end

  test "event-triggered refresh emits source=event with events_absorbed", %{fake: fake} do
    session = "wrt-evt-#{System.unique_integer([:positive])}"
    put_fake_topology(session, "shell", "bash")

    assert {:ok, _pid} =
             Watcher.ensure_started(
               session,
               watcher_opts(fake, enabled: true, refresh_ms: 50, reconcile_ms: 60_000)
             )

    # Drain init / subscribe snapshots (manual/reconcile from enter_event_mode).
    flush_refresh_telemetry()

    put_fake_topology(session, "tests", "mix")

    FakeEventSource.emit(fake, %{
      type: :window_renamed,
      window_id: "@1",
      raw: "%window-renamed @1 tests"
    })

    assert_receive {:watcher_refresh_telemetry, [:tmux_ctl, :topology, :watcher, :refresh],
                    %{count: 1, events_absorbed: absorbed}, %{source: :event, session: ^session}},
                   1_000

    assert absorbed >= 1
  end

  test "coalesced events report events_absorbed > 1 on the snapshot", %{fake: fake} do
    session = "wrt-coal-#{System.unique_integer([:positive])}"
    put_fake_topology(session, "shell", "bash")

    min_interval = 200

    assert {:ok, pid} =
             Watcher.ensure_started(
               session,
               watcher_opts(fake,
                 enabled: true,
                 refresh_ms: min_interval,
                 reconcile_ms: 60_000
               )
             )

    flush_refresh_telemetry()

    # Force last_refresh_ms to "now" so the next events must coalesce.
    _ = Watcher.refresh(session, watcher_opts(fake))
    flush_refresh_telemetry()

    FakeEventSource.emit(fake, %{type: :window_add, window_id: "@2"})
    FakeEventSource.emit(fake, %{type: :window_add, window_id: "@3"})
    FakeEventSource.emit(fake, %{type: :window_add, window_id: "@4"})

    assert_receive {:watcher_refresh_telemetry, [:tmux_ctl, :topology, :watcher, :refresh],
                    %{count: 1, events_absorbed: absorbed}, %{source: :event, session: ^session}},
                   min_interval + 500

    assert absorbed >= 2
    assert Process.alive?(pid)
  end

  test "poll fallback timer emits source=poll_fallback when event_mode is off" do
    session = "wrt-poll-#{System.unique_integer([:positive])}"
    put_fake_topology(session, "shell", "bash")

    # Mirrors the proven watcher_events_test opts exactly (same registry/
    # supervisor/idle_stop/broadcast shape) — only event_source: nil differs,
    # putting the watcher on the pure poll path. An earlier variant of this
    # test with bespoke opts hung in ensure_started on the gate runner.
    opts = [
      registry: @registry,
      supervisor: @supervisor,
      pubsub: DevIDE.PubSub,
      tmux_resolver: fn -> TmuxCtl.Test.FakeAdapter end,
      broadcast_tag: @tag,
      refresh_ms: 50,
      reconcile_ms: 60_000,
      event_source: nil,
      idle_stop_ms: 60_000
    ]

    :ok = Watcher.subscribe(session, opts)
    assert {:ok, _pid} = Watcher.ensure_started(session, Keyword.put(opts, :enabled, true))

    flush_refresh_telemetry()

    assert_receive {:watcher_refresh_telemetry, [:tmux_ctl, :topology, :watcher, :refresh],
                    %{count: 1}, %{source: :poll_fallback, session: ^session}},
                   2_000
  end

  defp flush_refresh_telemetry do
    receive do
      {:watcher_refresh_telemetry, _, _, _} -> flush_refresh_telemetry()
    after
      50 -> :ok
    end
  end

  defp put_fake_topology(session, window_name, command) do
    FakeState.update(:fake_tmux_windows, %{}, fn windows ->
      Map.put(windows, session, [
        %{
          id: "@1",
          index: 0,
          name: window_name,
          active: true,
          panes: 1,
          activity: 10,
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
          activity: 10,
          activity_flag: true,
          bell: false,
          unseen_changes: true
        }
      ]
    })
  end

  defp watcher_opts(fake, extra \\ []) do
    [
      registry: @registry,
      supervisor: @supervisor,
      pubsub: DevIDE.PubSub,
      broadcast_tag: @tag,
      topic_prefix: "terminal_topology:",
      tmux_resolver: fn -> TmuxCtl.Test.FakeAdapter end,
      event_source: {FakeEventSource, fake},
      idle_stop_ms: 60_000
    ]
    |> Keyword.merge(extra)
  end
end
