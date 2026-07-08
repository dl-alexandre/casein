defmodule DevIDE.Signals.DegradationWatchTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Audit
  alias DevIDE.Audit.MemoryAdapter
  alias DevIDE.Signals
  alias DevIDE.Signals.DegradationWatch

  # threshold intentionally low so tests stay fast; wide window so wall-clock
  # jitter never ages a signal out mid-test.
  @rule %{
    action: "workspace.db_isolation_detected",
    fingerprint: ["isolation", "source"],
    threshold: 3,
    window_ms: 60_000
  }

  setup do
    prev = Application.get_env(:dev_ide, :audit_adapter)
    Application.put_env(:dev_ide, :audit_adapter, MemoryAdapter)
    MemoryAdapter.clear()

    on_exit(fn ->
      MemoryAdapter.clear()
      restore(prev)
    end)

    :ok
  end

  defp restore(nil), do: Application.delete_env(:dev_ide, :audit_adapter)
  defp restore(v), do: Application.put_env(:dev_ide, :audit_adapter, v)

  # A private watcher fed by hand (subscribe?: false) so the shared bus-attached
  # instance never sees these synthetic signals.
  defp start_watch(rules \\ [@rule]) do
    name = :"degradation_watch_#{System.unique_integer([:positive])}"
    start_supervised!({DegradationWatch, rules: rules, subscribe?: false, name: name})
  end

  defp feed(pid, ws, metadata, action \\ "workspace.db_isolation_detected") do
    event = %Audit.Event{
      id: "ev-#{System.unique_integer([:positive])}",
      action: action,
      workspace_id: ws,
      actor_id: "system",
      target_type: "workspace",
      target_ref: ws,
      decision: nil,
      reason: nil,
      metadata: metadata,
      inserted_at: DateTime.utc_now()
    }

    send(pid, {:signal, Signals.from_audit_event(event)})
  end

  # :sys.get_state flushes the mailbox (the {:signal, _} sends are processed
  # first), so after it the watcher has observed every fed signal.
  defp storms_for(pid, ws) do
    _ = :sys.get_state(pid)

    ws
    |> Audit.recent_for(50)
    |> Enum.filter(&(&1.action == DegradationWatch.storm_action()))
  end

  @degraded %{"isolation" => "unknown", "source" => "none"}

  test "no storm below the threshold" do
    pid = start_watch()
    for _ <- 1..2, do: feed(pid, "w1", @degraded)

    assert storms_for(pid, "w1") == []
  end

  test "an identical degraded payload repeating past the threshold fires one storm" do
    pid = start_watch()
    for _ <- 1..3, do: feed(pid, "w2", @degraded)

    assert [storm] = storms_for(pid, "w2")
    assert storm.metadata["watched_action"] == "workspace.db_isolation_detected"
    assert storm.metadata["fingerprint"] == ["unknown", "none"]
    assert storm.metadata["count"] >= 3
  end

  test "one episode fires once, not once per signal past the threshold" do
    pid = start_watch()
    for _ <- 1..6, do: feed(pid, "w3", @degraded)

    assert length(storms_for(pid, "w3")) == 1
  end

  test "distinct fingerprints do not aggregate into a storm" do
    pid = start_watch()
    # Two of each classification — neither reaches the threshold of 3.
    for _ <- 1..2, do: feed(pid, "w4", %{"isolation" => "unknown", "source" => "none"})
    for _ <- 1..2, do: feed(pid, "w4", %{"isolation" => "local", "source" => "env_file"})

    assert storms_for(pid, "w4") == []
  end

  test "the storm event itself matches no rule, so it cannot loop" do
    pid = start_watch()
    for _ <- 1..5, do: feed(pid, "w5", @degraded, DegradationWatch.storm_action())

    assert storms_for(pid, "w5") == []
  end
end
