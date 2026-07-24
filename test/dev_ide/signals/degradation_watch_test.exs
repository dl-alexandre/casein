defmodule Casein.Signals.DegradationWatchTest do
  use Casein.TestCase, async: false

  alias Casein.Audit
  alias Casein.Audit.MemoryAdapter
  alias Casein.Signals
  alias Casein.Signals.DegradationWatch

  # threshold intentionally low so tests stay fast; wide window so wall-clock
  # jitter never ages a signal out mid-test.
  @rule %{
    action: "workspace.db_isolation_detected",
    fingerprint: ["isolation", "source"],
    threshold: 3,
    window_ms: 60_000
  }

  setup do
    prev = Application.get_env(:casein, :audit_adapter)
    Application.put_env(:casein, :audit_adapter, MemoryAdapter)
    MemoryAdapter.clear()

    on_exit(fn ->
      MemoryAdapter.clear()
      restore(prev)
    end)

    :ok
  end

  defp restore(nil), do: Application.delete_env(:casein, :audit_adapter)
  defp restore(v), do: Application.put_env(:casein, :audit_adapter, v)

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

  # Feed a non-audit domain signal (devide.<event> namespace, per #184).
  defp feed_domain(pid, event, ws, data) do
    send(pid, {:signal, Signals.from_domain_event(event, data, workspace_id: ws)})
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

  test "a domain-event (devide.*) failure storm fires, keyed on the full type" do
    rule = %{action: "devide.deploy.failed", fingerprint: [], threshold: 3, window_ms: 60_000}
    pid = start_watch([rule])

    for _ <- 1..3, do: feed_domain(pid, "deploy.failed", "wdeploy", %{"reason" => "boom"})

    assert [storm] = storms_for(pid, "wdeploy")
    assert storm.metadata["watched_action"] == "devide.deploy.failed"
  end

  test "domain subscription patterns cover audit wildcard plus each domain rule type" do
    rules = %{
      "workspace.db_isolation_detected" => %{},
      "devide.deploy.failed" => %{},
      "devide.runtime.preview_failed" => %{}
    }

    patterns = DegradationWatch.subscription_patterns(rules)
    assert "devide.audit.**" in patterns
    assert "devide.deploy.failed" in patterns
    assert "devide.runtime.preview_failed" in patterns
    # audit rule keys are NOT subscribed individually (covered by the wildcard)
    refute "workspace.db_isolation_detected" in patterns
  end
end
