defmodule Casein.Signals.MemoryPressureWatchTest do
  use Casein.TestCase, async: false

  alias Casein.Audit
  alias Casein.Audit.MemoryAdapter
  alias Casein.Signals.MemoryPressureWatch

  @ops_ws "_ops"

  setup do
    previous_adapter = Application.fetch_env!(:casein, :audit_adapter)
    previous_config = Application.fetch_env!(:casein, :memory_pressure_watch)

    Application.put_env(:casein, :audit_adapter, MemoryAdapter)
    MemoryAdapter.clear()

    on_exit(fn ->
      MemoryAdapter.clear()
      Application.put_env(:casein, :audit_adapter, previous_adapter)
      Application.put_env(:casein, :memory_pressure_watch, previous_config)
    end)

    :ok
  end

  test "a sustained threshold crossing fires exactly once" do
    pid = start_watch([84, 85, 90, 95, 97])

    take_samples(pid, 5)

    assert length(audits(MemoryPressureWatch.warning_action())) == 1
    assert length(audits(MemoryPressureWatch.alarm_action())) == 1
    assert audits(MemoryPressureWatch.recovered_action()) == []
  end

  test "dropping below the threshold re-arms a pressure episode" do
    pid = start_watch([96, 97, 60, 96])

    take_samples(pid, 4)

    assert length(audits(MemoryPressureWatch.alarm_action())) == 2
    assert length(audits(MemoryPressureWatch.recovered_action())) == 1
  end

  test "the alarm carries the agent slice share so the operator knows where to look" do
    pid = start_watch([96], agent_slice_used_percent: 88.0)

    take_samples(pid, 1)

    assert [event] = audits(MemoryPressureWatch.alarm_action())
    assert event.metadata["agent_slice_used_percent"] == 88.0
    assert event.metadata["used_percent"] == 96
    assert event.metadata["level"] == "alarm"
  end

  test "broadcasts raised/cleared on ops:health" do
    Phoenix.PubSub.subscribe(Casein.PubSub, "ops:health")
    pid = start_watch([96, 50])

    take_samples(pid, 2)

    assert_receive {:ops_health, :memory_pressure, :raised,
                    %{id: :memory_pressure, severity: :alarm}}

    assert_receive {:ops_health, :memory_pressure, :cleared, %{severity: :info}}
  end

  test "recent sample ring obeys the count cap" do
    pid = start_watch([10, 20, 30, 40, 50], sample_cap: 3)

    take_samples(pid, 5)

    assert Enum.map(MemoryPressureWatch.recent_samples(pid), & &1.used_percent) == [50, 40, 30]
  end

  test "sampler failure is reported, not classified" do
    Application.put_env(:casein, :memory_pressure_watch, base_config(fn -> {:error, :nope} end))
    name = :"memory_pressure_watch_#{System.unique_integer([:positive])}"
    pid = start_supervised!({MemoryPressureWatch, name: name, schedule?: false})

    assert {:error, :nope} = MemoryPressureWatch.sample_now(pid)
    assert audits(MemoryPressureWatch.warning_action()) == []
  end

  describe "sample_memory/1" do
    test "reads used percent from MemTotal/MemAvailable, treating cache as free" do
      path = write_meminfo!("MemTotal: 1000000 kB\nMemFree: 100000 kB\nMemAvailable: 400000 kB\n")

      assert {:ok, %{used_percent: 60.0, mem_total_kb: 1_000_000, mem_available_kb: 400_000}} =
               MemoryPressureWatch.sample_memory(meminfo_path: path, agent_slice_dir: nil)
    end

    test "falls back to MemFree when MemAvailable is absent" do
      path = write_meminfo!("MemTotal: 1000 kB\nMemFree: 250 kB\n")

      assert {:ok, %{used_percent: 75.0, mem_available_kb: 250}} =
               MemoryPressureWatch.sample_memory(meminfo_path: path, agent_slice_dir: nil)
    end

    test "folds in the agent slice share when its cgroup files are readable" do
      path = write_meminfo!("MemTotal: 1000 kB\nMemAvailable: 500 kB\n")
      dir = tmp_dir!()
      File.write!(Path.join(dir, "memory.current"), "2048\n")
      File.write!(Path.join(dir, "memory.high"), "4096\n")

      assert {:ok,
              %{agent_slice_used_percent: 50.0, agent_slice_current_kb: 2, agent_slice_high_kb: 4}} =
               MemoryPressureWatch.sample_memory(meminfo_path: path, agent_slice_dir: dir)
    end

    test "an uncapped slice (memory.high=max) reports no share" do
      path = write_meminfo!("MemTotal: 1000 kB\nMemAvailable: 500 kB\n")
      dir = tmp_dir!()
      File.write!(Path.join(dir, "memory.current"), "2048\n")
      File.write!(Path.join(dir, "memory.high"), "max\n")

      assert {:ok, %{agent_slice_used_percent: nil, agent_slice_high_kb: nil}} =
               MemoryPressureWatch.sample_memory(meminfo_path: path, agent_slice_dir: dir)
    end

    test "unreadable or malformed meminfo is an error, never a classification" do
      assert {:error, {:meminfo_unreadable, :enoent}} =
               MemoryPressureWatch.sample_memory(
                 meminfo_path: "/nonexistent/meminfo",
                 agent_slice_dir: nil
               )

      path = write_meminfo!("garbage\n")

      assert {:error, :meminfo_malformed} =
               MemoryPressureWatch.sample_memory(meminfo_path: path, agent_slice_dir: nil)
    end

    @tag :linux_only
    test "production sampler reads the live host when /proc/meminfo exists" do
      if File.exists?("/proc/meminfo") do
        assert {:ok, %{used_percent: pct, mem_total_kb: total}} =
                 MemoryPressureWatch.sample_memory()

        assert total > 0
        assert pct >= 0 and pct <= 100
      end
    end
  end

  defp start_watch(used_percents, opts \\ []) do
    {:ok, samples} = Agent.start_link(fn -> used_percents end)
    clock_values = Keyword.get(opts, :clock_values, Enum.to_list(1..length(used_percents)))
    {:ok, clock} = Agent.start_link(fn -> clock_values end)
    slice_pct = Keyword.get(opts, :agent_slice_used_percent)

    sampler = fn ->
      Agent.get_and_update(samples, fn [used_percent | rest] ->
        sample = %{
          used_percent: used_percent,
          mem_total_kb: 1_000_000,
          mem_available_kb: 1_000_000 - div(used_percent * 1_000_000, 100)
        }

        sample =
          if slice_pct,
            do: Map.put(sample, :agent_slice_used_percent, slice_pct),
            else: sample

        {{:ok, sample}, rest}
      end)
    end

    clock_fun = fn ->
      Agent.get_and_update(clock, fn [now | rest] -> {now, rest} end)
    end

    Application.put_env(
      :casein,
      :memory_pressure_watch,
      base_config(sampler,
        clock: clock_fun,
        sample_cap: Keyword.get(opts, :sample_cap, 120),
        sample_retention_ms: Keyword.get(opts, :sample_retention_ms, 7_200_000)
      )
    )

    name = :"memory_pressure_watch_#{System.unique_integer([:positive])}"
    start_supervised!({MemoryPressureWatch, name: name, schedule?: false})
  end

  defp base_config(sampler, opts \\ []) do
    [
      warning_percent: 85,
      alarm_percent: 95,
      healthy_interval_ms: 60_000,
      warning_interval_ms: 30_000,
      alarm_interval_ms: 10_000,
      sample_cap: Keyword.get(opts, :sample_cap, 120),
      sample_retention_ms: Keyword.get(opts, :sample_retention_ms, 7_200_000),
      sampler: sampler,
      clock: Keyword.get(opts, :clock, {System, :monotonic_time, [:millisecond]})
    ]
  end

  defp take_samples(pid, count) do
    for _ <- 1..count do
      assert {:ok, _sample} = MemoryPressureWatch.sample_now(pid)
    end
  end

  defp audits(action) do
    _ = :sys.get_state(MemoryAdapter)

    @ops_ws
    |> Audit.recent_for(50)
    |> Enum.filter(&(&1.action == action))
  end

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "memwatch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_meminfo!(contents) do
    path = Path.join(tmp_dir!(), "meminfo")
    File.write!(path, contents)
    path
  end
end
