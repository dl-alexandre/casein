defmodule Casein.Signals.HostWatchdogWatchTest do
  use Casein.TestCase, async: false

  alias Casein.Audit
  alias Casein.Audit.MemoryAdapter
  alias Casein.Signals.HostWatchdogWatch
  alias Casein.Terminals.HostHealth

  @ops_ws "_ops"
  @now ~U[2026-08-30 16:03:36Z]

  setup do
    previous_adapter = Application.fetch_env!(:casein, :audit_adapter)
    Application.put_env(:casein, :audit_adapter, MemoryAdapter)
    MemoryAdapter.clear()

    on_exit(fn ->
      MemoryAdapter.clear()
      Application.put_env(:casein, :audit_adapter, previous_adapter)
    end)

    :ok
  end

  test "classifies only a fresh snapshot as fresh" do
    assert HostWatchdogWatch.classify(fresh_snapshot()) == :fresh
    assert HostWatchdogWatch.classify(stale_snapshot()) == :stale
    assert HostWatchdogWatch.classify(unknown_snapshot()) == :stale
  end

  test "a dead watchdog raises once, after the confirm window, with the staleness as evidence" do
    pid = start_watch([fresh_snapshot(), stale_snapshot(), stale_snapshot(), stale_snapshot()])

    take_samples(pid, 2)
    assert audits(HostWatchdogWatch.stale_action()) == []

    take_samples(pid, 2)
    assert [event] = audits(HostWatchdogWatch.stale_action())
    assert event.metadata["state"] == "stale"
    assert event.metadata["recorded_state"] == "stuck"
    assert event.metadata["sampled_at"] == "2026-08-27T21:10:23Z"
    assert event.metadata["age_seconds"] == 240_793
    assert event.metadata["alerts_available"] == false
  end

  test "a missing snapshot (unknown) counts as dead too" do
    pid = start_watch([unknown_snapshot(), unknown_snapshot()])
    take_samples(pid, 2)

    assert [event] = audits(HostWatchdogWatch.stale_action())
    assert event.metadata["state"] == "unknown"
  end

  test "the first fresh sample clears immediately and re-arms" do
    pid =
      start_watch([
        stale_snapshot(),
        stale_snapshot(),
        fresh_snapshot(),
        stale_snapshot(),
        stale_snapshot()
      ])

    take_samples(pid, 5)

    assert length(audits(HostWatchdogWatch.stale_action())) == 2
    assert [recovered] = audits(HostWatchdogWatch.recovered_action())
    assert recovered.metadata["state"] == "healthy"
  end

  test "broadcasts raised/cleared on ops:health with a suggestion naming the timer" do
    Phoenix.PubSub.subscribe(Casein.PubSub, "ops:health")
    pid = start_watch([stale_snapshot(), stale_snapshot(), fresh_snapshot()])
    take_samples(pid, 3)

    assert_receive {:ops_health, :host_watchdog, :raised,
                    %{severity: :warn, suggestion: suggestion}}

    assert suggestion =~ "66h"
    assert suggestion =~ "casein-host-watchdog.timer"
    assert_receive {:ops_health, :host_watchdog, :cleared, %{severity: :info}}
  end

  test "a sampler crash is reported, never classified" do
    name = :"host_watchdog_watch_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {HostWatchdogWatch,
         name: name,
         schedule?: false,
         interval_ms: 300_000,
         confirm_samples: 1,
         sampler: fn -> raise "boom" end}
      )

    assert {:error, %RuntimeError{}} = HostWatchdogWatch.sample_now(pid)
    assert audits(HostWatchdogWatch.stale_action()) == []
  end

  defp start_watch(snapshots) do
    {:ok, queue} = Agent.start_link(fn -> snapshots end)
    sampler = fn -> Agent.get_and_update(queue, fn [snap | rest] -> {snap, rest} end) end
    name = :"host_watchdog_watch_#{System.unique_integer([:positive])}"

    start_supervised!(
      {HostWatchdogWatch,
       name: name, schedule?: false, interval_ms: 300_000, confirm_samples: 2, sampler: sampler}
    )
  end

  defp take_samples(pid, count) do
    for _ <- 1..count, do: assert({:ok, _} = HostWatchdogWatch.sample_now(pid))
  end

  defp fresh_snapshot do
    HostHealth.snapshot(
      status: sample(%{"timestamp" => "2026-08-30T16:03:26Z"}),
      alerts: [],
      now: @now,
      host: "milc-devbox"
    )
  end

  # The real numbers from OneBackend-v3#20165: the crash-time sample, 66.9h old.
  defp stale_snapshot do
    HostHealth.snapshot(
      status:
        sample(%{
          "timestamp" => "2026-08-27T21:10:23Z",
          "load1" => 781.49,
          "cpu_idle_pct" => 0,
          "d_state_processes" => 224,
          "d_state_streak" => 10,
          "warning" => 1,
          "alert" => "pressure_and_d_state"
        }),
      alerts_raw: nil,
      now: @now,
      host: "milc-devbox"
    )
  end

  defp unknown_snapshot do
    HostHealth.snapshot(status_raw: nil, alerts: [], now: @now, host: "milc-devbox")
  end

  defp sample(overrides) do
    Map.merge(
      %{
        "timestamp" => "2026-08-30T16:03:26Z",
        "load1" => 11.36,
        "runnable" => 7,
        "cpu_idle_pct" => 80,
        "mem_available_kb" => 80_344_404,
        "swap_used_kb" => 0,
        "d_state_processes" => 0,
        "d_state_streak" => 0,
        "opencode_processes" => 1,
        "beam_processes" => 4,
        "warning" => 0,
        "alert" => "none"
      },
      overrides
    )
  end

  defp audits(action) do
    _ = :sys.get_state(MemoryAdapter)

    @ops_ws
    |> Audit.recent_for(50)
    |> Enum.filter(&(&1.action == action))
  end
end
