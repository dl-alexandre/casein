defmodule DevIDE.SignalsTest do
  use ExUnit.Case, async: true

  alias DevIDE.Audit.Event
  alias DevIDE.Signals
  alias Jido.Signal.Trace

  test "type_for prefixes audit actions" do
    assert Signals.type_for("agent.blocked") == "devide.audit.agent.blocked"
    assert String.starts_with?(Signals.type_for("x"), Signals.type_prefix())
  end

  test "from_audit_event builds a CloudEvents envelope sharing the event id" do
    event =
      Event.new(%{
        workspace_id: "ws-1",
        actor_id: "agent",
        action: "agent.blocked",
        target_type: "tmux_pane",
        target_ref: "%3",
        metadata: %{"message" => "needs perm"}
      })

    signal = Signals.from_audit_event(event)

    assert signal.type == "devide.audit.agent.blocked"
    assert signal.id == event.id
    assert signal.source == "/devide/audit/ws-1"
    assert signal.subject == "%3"
    assert signal.time == DateTime.to_iso8601(event.inserted_at)
    assert signal.data.action == "agent.blocked"
    assert signal.data.metadata["message"] == "needs perm"
    assert Trace.get(signal) == nil
  end

  test "correlation metadata becomes the signal's trace extension" do
    event =
      Event.new(%{
        workspace_id: "ws-1",
        action: "run.started",
        metadata: %{"correlation_id" => "abc123", "causation_id" => "evt-0"}
      })

    ctx = event |> Signals.from_audit_event() |> Trace.get()

    assert ctx.trace_id == "abc123"
    assert ctx.causation_id == "evt-0"
    assert is_binary(ctx.span_id)
  end

  test "events without a workspace map to the global source" do
    event = Event.new(%{action: "system.check"})
    assert Signals.from_audit_event(event).source == "/devide/audit/global"
  end

  test "from_signal round-trips audit event fields" do
    event =
      Event.new(%{
        workspace_id: "ws-1",
        actor_id: "agent",
        action: "agent.blocked",
        target_type: "tmux_pane",
        target_ref: "%3",
        decision: :deny,
        reason: :needs_permission,
        metadata: %{"correlation_id" => "abc", "session_id" => "run-1"}
      })

    signal = Signals.from_audit_event(event)
    roundtrip = Event.from_signal(signal)

    assert roundtrip.id == event.id
    assert roundtrip.workspace_id == event.workspace_id
    assert roundtrip.action == event.action
    assert roundtrip.target_ref == event.target_ref
    assert roundtrip.decision == event.decision
    assert roundtrip.reason == event.reason
    assert roundtrip.metadata["correlation_id"] == "abc"
  end
end
