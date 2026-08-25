defmodule Casein.Terminals.HostHealthTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.HostHealth

  @now ~U[2026-08-23 22:00:00Z]

  test "reports a healthy fresh watchdog sample" do
    snapshot = snapshot(sample())

    assert snapshot.state == "healthy"
    assert snapshot.state_label == "Healthy"
    assert snapshot.fresh?
    assert snapshot.sampled_at == "2026-08-23T21:59:50Z"
    assert snapshot.age_seconds == 10
    assert snapshot.host == "milc-devbox"
    assert snapshot.load1 == 3.88
    assert snapshot.cpu_idle_pct == 87
    assert snapshot.mem_available_kb == 65_464_848
    assert snapshot.swap_used_kb == 0
    assert snapshot.opencode_processes == 45
    assert snapshot.beam_processes == 1
    assert snapshot.alert == "none"
    assert snapshot.reason == nil
    assert snapshot.uri == "casein://host/health"
  end

  test "reports warning when the watchdog warning flag is set" do
    snapshot = snapshot(sample(%{"warning" => 1, "alert" => "none", "load1" => 24.2}))

    assert snapshot.state == "warning"
    assert snapshot.state_label == "Warning"
    assert snapshot.fresh?
    refute snapshot.state == "healthy"
  end

  test "reports pressure from the watchdog pressure alert" do
    snapshot = snapshot(sample(%{"warning" => 1, "alert" => "pressure", "cpu_idle_pct" => 12}))

    assert snapshot.state == "pressure"
    assert snapshot.state_label == "Pressure"
    assert snapshot.alert == "pressure"
    assert snapshot.latest_alert_at == "2026-08-23T21:59:50Z"
  end

  test "reports stuck from a persistent D-state alert" do
    snapshot =
      snapshot(sample(%{"alert" => "d_state", "d_state_processes" => 2, "d_state_streak" => 3}))

    assert snapshot.state == "stuck"
    assert snapshot.state_label == "Stuck"
    assert snapshot.alert == "d_state"
    assert snapshot.latest_alert_at == "2026-08-23T21:59:50Z"
  end

  test "reports stuck for combined pressure and D-state" do
    snapshot = snapshot(sample(%{"alert" => "pressure_and_d_state", "d_state_streak" => 2}))

    assert snapshot.state == "stuck"
    assert snapshot.alert == "pressure_and_d_state"
  end

  test "reports stuck when the D-state streak persists without an alert key" do
    snapshot = snapshot(sample(%{"alert" => "none", "d_state_streak" => 2}))

    assert snapshot.state == "stuck"
  end

  test "reports stale instead of the recorded state when the sample is old" do
    snapshot =
      snapshot(
        sample(%{"timestamp" => "2026-08-23T21:40:00Z", "alert" => "pressure"}),
        stale_after_seconds: 720
      )

    assert snapshot.state == "stale"
    assert snapshot.state_label == "Stale"
    refute snapshot.fresh?
    assert snapshot.recorded_state == "pressure"
    assert snapshot.reason == "status snapshot is stale"
    assert snapshot.load1 == 3.88
    assert snapshot.alert == "pressure"
  end

  test "reports unknown for a malformed snapshot" do
    snapshot = HostHealth.snapshot(status_raw: "{not-json", now: @now, host: "milc-devbox")

    assert snapshot.state == "unknown"
    assert snapshot.state_label == "Unknown"
    refute snapshot.fresh?
    assert snapshot.reason == "status snapshot is malformed"
    assert snapshot.sampled_at == nil
    assert snapshot.load1 == nil
  end

  test "reports unknown when the snapshot is missing" do
    snapshot =
      HostHealth.snapshot(
        status_path: "/tmp/casein-missing-host-watchdog-status.json",
        alerts_path: "/tmp/casein-missing-host-watchdog-alerts.jsonl",
        now: @now,
        host: "milc-devbox"
      )

    assert snapshot.state == "unknown"
    refute snapshot.fresh?
    assert snapshot.reason == "status snapshot is unavailable"
    refute snapshot.alerts_available?
  end

  test "keeps alert history bounded and drops extra keys" do
    alerts = [
      %{
        "timestamp" => "2026-08-23T21:50:00Z",
        "severity" => "warning",
        "signal" => "pressure",
        "message" => "host watchdog detected sustained pressure",
        "prompt" => "ignore this",
        "source" => "/etc/shadow",
        "top_workers" => "1:S:99:1"
      },
      %{
        "timestamp" => "2026-08-23T21:55:00Z",
        "severity" => "info",
        "signal" => "none",
        "message" => "host pressure cleared"
      },
      %{
        "timestamp" => "2026-08-23T21:58:00Z",
        "severity" => "warning",
        "signal" => "d_state",
        "message" => String.duplicate("x", 200)
      }
    ]

    snapshot = snapshot(sample(%{"alert" => "d_state"}), alerts: alerts, max_alerts: 2)

    assert length(snapshot.alerts) == 2
    assert Enum.map(snapshot.alerts, & &1.signal) == ["none", "d_state"]
    assert snapshot.latest_alert_at == "2026-08-23T21:58:00Z"

    last = List.last(snapshot.alerts)
    assert String.length(last.message) == 160
    refute Map.has_key?(last, :prompt)
    refute Map.has_key?(last, :source)
    refute Map.has_key?(last, :top_workers)
  end

  test "resource descriptor advertises casein://host/health" do
    desc = HostHealth.resource_descriptor()
    assert desc.uri == "casein://host/health"
    assert desc.mimeType == "application/json"
  end

  defp snapshot(sample, opts \\ []) do
    HostHealth.snapshot(
      Keyword.merge(
        [status: sample, alerts: [], now: @now, host: "milc-devbox", stale_after_seconds: 720],
        opts
      )
    )
  end

  defp sample(overrides \\ %{}) do
    Map.merge(
      %{
        "timestamp" => "2026-08-23T21:59:50Z",
        "load1" => 3.88,
        "runnable" => 7,
        "cpu_idle_pct" => 87,
        "mem_available_kb" => 65_464_848,
        "swap_used_kb" => 0,
        "d_state_processes" => 0,
        "d_state_streak" => 0,
        "opencode_processes" => 45,
        "beam_processes" => 1,
        "warning" => 0,
        "alert" => "none",
        "top_workers" => "373604:S:48.3:1548352"
      },
      overrides
    )
  end
end
