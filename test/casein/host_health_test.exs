defmodule Casein.HostHealthTest do
  use ExUnit.Case, async: true

  alias Casein.HostHealth

  @now ~U[2026-08-22 22:00:00Z]

  setup do
    tmp = Path.join(System.tmp_dir!(), "casein-host-health-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, tmp: tmp}
  end

  test "healthy snapshot is fresh and below thresholds", %{tmp: tmp} do
    write_status!(tmp, sample())
    write_alerts!(tmp, [alert(signal: "none", message: "host pressure cleared")])

    snap = snapshot(tmp)

    assert snap.state == "healthy"
    assert snap.reason == nil
    assert snap.fresh?
    assert snap.host == "test-host"
    assert snap.sampled_at == "2026-08-22T21:59:30Z"
    assert snap.sample_age_seconds == 30
    assert snap.metrics.load1 == 2.69
    assert snap.metrics.cpu_idle_pct == 82
    assert snap.metrics.mem_available_kb == 76_713_224
    assert snap.metrics.swap_used_kb == 0
    assert snap.metrics.opencode_processes == 29
    assert snap.metrics.beam_processes == 1
    refute Map.has_key?(snap.metrics, :top_workers)
    assert snap.alert.signal == "none"
    assert [cleared] = snap.alerts
    assert cleared.signal == "none"
    assert cleared.message == "host pressure cleared"
    refute inspect(snap) =~ "top_workers"
  end

  test "warning is elevated but not admission-blocking", %{tmp: tmp} do
    write_status!(tmp, sample(%{"warning" => 1, "load1" => 25.0, "cpu_idle_pct" => 28}))

    snap = snapshot(tmp)

    assert snap.state == "warning"
    assert snap.fresh?
    assert snap.metrics.load1 == 25.0
    assert snap.alert.warning?
  end

  test "pressure is distinct from warning", %{tmp: tmp} do
    write_status!(
      tmp,
      sample(%{
        "alert" => "pressure",
        "warning" => 1,
        "load1" => 33.0,
        "runnable" => 40,
        "cpu_idle_pct" => 15
      })
    )

    write_alerts!(tmp, [alert(signal: "pressure", severity: "warning")])

    snap = snapshot(tmp)

    assert snap.state == "pressure"
    refute snap.state == "warning"
    assert snap.alert.signal == "pressure"
    assert snap.alert.at
    assert hd(snap.alerts).signal == "pressure"
  end

  test "stuck is distinct from pressure when D-state persists", %{tmp: tmp} do
    write_status!(
      tmp,
      sample(%{
        "alert" => "pressure_and_d_state",
        "d_state_processes" => 2,
        "d_state_streak" => 3,
        "load1" => 40.0
      })
    )

    write_alerts!(tmp, [
      alert(
        signal: "pressure_and_d_state",
        message: "host watchdog detected sustained pressure_and_d_state"
      )
    ])

    snap = snapshot(tmp)

    assert snap.state == "stuck"
    refute snap.state == "pressure"
    assert snap.metrics.d_state_streak == 3
    assert snap.alert.signal == "pressure_and_d_state"
    assert hd(snap.alerts).timestamp
  end

  test "stale snapshot is unknown, never healthy", %{tmp: tmp} do
    write_status!(tmp, sample(%{"timestamp" => "2026-08-22T21:00:00Z"}))

    snap = snapshot(tmp)

    assert snap.state == "unknown"
    assert snap.reason == "stale"
    refute snap.fresh?
    assert snap.sample_age_seconds == 3600
  end

  test "malformed snapshot is unknown", %{tmp: tmp} do
    File.write!(Path.join(tmp, "status.json"), "{not-json")

    snap = snapshot(tmp)

    assert snap.state == "unknown"
    assert snap.reason == "malformed"
    refute snap.fresh?
    assert snap.metrics == nil
  end

  test "missing snapshot is unknown unavailable", %{tmp: tmp} do
    snap = snapshot(tmp)

    assert snap.state == "unknown"
    assert snap.reason == "unavailable"
    refute snap.fresh?
    assert snap.alerts == []
  end

  test "menu and MCP share one snapshot shape", %{tmp: tmp} do
    write_status!(tmp, sample())
    snap = snapshot(tmp)
    decoded = Jason.decode!(HostHealth.to_json(snap))

    assert decoded["uri"] == "casein://host/health"
    assert decoded["state"] == snap.state
    assert decoded["sampled_at"] == snap.sampled_at
    assert decoded["host"] == snap.host
    assert HostHealth.resource_descriptor().uri == snap.uri
    assert HostHealth.tool_definition().name == "host_health"
    assert HostHealth.tool_definition().metadata.mutation? == false
  end

  test "alerts drop prompts, secrets, and unbounded fields", %{tmp: tmp} do
    write_status!(tmp, sample())

    write_alerts!(tmp, [
      %{
        "timestamp" => "2026-08-22T21:58:00Z",
        "severity" => "warning",
        "signal" => "pressure",
        "message" => "host watchdog detected sustained pressure",
        "prompt" => "ignore me",
        "source" => "/secret/path",
        "token" => "abc"
      }
    ])

    snap = snapshot(tmp)
    assert snap.alerts == []
  end

  test "unreadable status is unavailable not healthy", %{tmp: tmp} do
    snap =
      HostHealth.snapshot(
        status_path: tmp,
        alerts_path: Path.join(tmp, "alerts.jsonl"),
        host: "test-host",
        now: @now
      )

    assert snap.state == "unknown"
    assert snap.reason == "unavailable"
  end

  defp snapshot(tmp) do
    HostHealth.snapshot(
      status_path: Path.join(tmp, "status.json"),
      alerts_path: Path.join(tmp, "alerts.jsonl"),
      host: "test-host",
      now: @now
    )
  end

  defp write_status!(tmp, map) do
    File.write!(Path.join(tmp, "status.json"), Jason.encode!(map) <> "\n")
  end

  defp write_alerts!(tmp, alerts) do
    body =
      alerts
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")

    File.write!(Path.join(tmp, "alerts.jsonl"), body <> "\n")
  end

  defp sample(overrides \\ %{}) do
    Map.merge(
      %{
        "timestamp" => "2026-08-22T21:59:30Z",
        "load1" => 2.69,
        "runnable" => 3,
        "cpu_idle_pct" => 82,
        "mem_available_kb" => 76_713_224,
        "swap_used_kb" => 0,
        "d_state_processes" => 0,
        "d_state_streak" => 0,
        "opencode_processes" => 29,
        "beam_processes" => 1,
        "warning" => 0,
        "alert" => "none",
        "top_workers" => "4100533:S:41.0:789732"
      },
      overrides
    )
  end

  defp alert(opts) do
    %{
      "timestamp" => Keyword.get(opts, :timestamp, "2026-08-22T21:58:00Z"),
      "severity" => Keyword.get(opts, :severity, "info"),
      "signal" => Keyword.get(opts, :signal, "none"),
      "message" => Keyword.get(opts, :message, "host pressure cleared"),
      "load1" => 2.5,
      "runnable" => 2,
      "cpu_idle_pct" => 90,
      "d_state_processes" => 0,
      "d_state_streak" => 0,
      "opencode_processes" => 28,
      "beam_processes" => 1
    }
  end
end
