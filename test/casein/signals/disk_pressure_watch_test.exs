defmodule Casein.Signals.DiskPressureWatchTest do
  use Casein.TestCase, async: false

  alias Casein.Audit
  alias Casein.Audit.MemoryAdapter
  alias Casein.Signals.DiskPressureWatch

  @ops_ws "_ops"

  setup do
    previous_adapter = Application.fetch_env!(:casein, :audit_adapter)
    previous_config = Application.fetch_env!(:casein, :disk_pressure_watch)

    Application.put_env(:casein, :audit_adapter, MemoryAdapter)
    MemoryAdapter.clear()

    on_exit(fn ->
      MemoryAdapter.clear()
      Application.put_env(:casein, :audit_adapter, previous_adapter)
      Application.put_env(:casein, :disk_pressure_watch, previous_config)
    end)

    :ok
  end

  test "a sustained threshold crossing fires exactly once" do
    pid = start_watch([84, 85, 90, 95, 97])

    take_samples(pid, 5)

    assert length(audits(DiskPressureWatch.warning_action())) == 1
    assert length(audits(DiskPressureWatch.alarm_action())) == 1
    assert audits(DiskPressureWatch.recovered_action()) == []
  end

  test "dropping below the threshold re-arms a pressure episode" do
    pid = start_watch([96, 97, 84, 96])

    take_samples(pid, 4)

    assert length(audits(DiskPressureWatch.alarm_action())) == 2
    assert length(audits(DiskPressureWatch.recovered_action())) == 1
  end

  test "recent sample ring obeys the count cap" do
    pid = start_watch([10, 20, 30, 40, 50], sample_cap: 3)

    take_samples(pid, 5)

    assert Enum.map(DiskPressureWatch.recent_samples(pid), & &1.used_percent) == [50, 40, 30]
  end

  test "sample age can win before the count cap" do
    pid = start_watch([10, 20, 30], clock_values: [0, 10, 200], sample_retention_ms: 100)

    take_samples(pid, 3)

    assert [%{used_percent: 30, sampled_at_ms: 200}] =
             DiskPressureWatch.recent_samples(pid)
  end

  test "sampling does not call filesystem write APIs" do
    pid = start_watch([50])
    traced = [{:file, :open, 2}, {:file, :write, 2}, {File, :write, 3}]

    Enum.each(traced, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(pid, true, [:call, {:tracer, self()}])

    on_exit(fn -> Enum.each(traced, &:erlang.trace_pattern(&1, false, [:local])) end)

    assert {:ok, %{used_percent: 50}} = DiskPressureWatch.sample_now(pid)
    refute_receive {:trace, ^pid, :call, _filesystem_write}
  end

  test "production sampler reads OTP disksup data" do
    assert {:ok, %{mount: "/", total_kb: total_kb, used_percent: used_percent}} =
             DiskPressureWatch.sample_disk_usage("/")

    assert total_kb > 0
    assert used_percent in 0..100
  end

  defp start_watch(used_percents, opts \\ []) do
    {:ok, samples} = Agent.start_link(fn -> used_percents end)
    clock_values = Keyword.get(opts, :clock_values, Enum.to_list(1..length(used_percents)))
    {:ok, clock} = Agent.start_link(fn -> clock_values end)

    sampler = fn mount ->
      Agent.get_and_update(samples, fn [used_percent | rest] ->
        {{:ok, %{mount: mount, total_kb: 1_000, used_percent: used_percent}}, rest}
      end)
    end

    clock_fun = fn ->
      Agent.get_and_update(clock, fn [now | rest] -> {now, rest} end)
    end

    Application.put_env(:casein, :disk_pressure_watch,
      mount: "/",
      warning_percent: 85,
      alarm_percent: 95,
      healthy_interval_ms: 60_000,
      warning_interval_ms: 30_000,
      alarm_interval_ms: 10_000,
      sample_cap: Keyword.get(opts, :sample_cap, 120),
      sample_retention_ms: Keyword.get(opts, :sample_retention_ms, 7_200_000),
      sampler: sampler,
      clock: clock_fun
    )

    name = :"disk_pressure_watch_#{System.unique_integer([:positive])}"
    start_supervised!({DiskPressureWatch, name: name, schedule?: false})
  end

  defp take_samples(pid, count) do
    for _ <- 1..count do
      assert {:ok, _sample} = DiskPressureWatch.sample_now(pid)
    end
  end

  defp audits(action) do
    _ = :sys.get_state(MemoryAdapter)

    @ops_ws
    |> Audit.recent_for(50)
    |> Enum.filter(&(&1.action == action))
  end
end
