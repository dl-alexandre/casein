defmodule DevIDE.Terminals.SessionEventsTest do
  use DevIDE.TestCase, async: true

  alias DevIDE.Terminals.SessionEvents

  test "delivers output events to topic subscribers" do
    assert :ok = SessionEvents.subscribe("ws-ev-1", "sid-1")
    assert :ok = SessionEvents.broadcast_output("ws-ev-1", "sid-1", 3)

    assert_receive {:terminal_session_event,
                    %{type: :output, workspace_id: "ws-ev-1", sid: "sid-1", gen: 3}}
  end

  test "does not deliver events for other sessions" do
    assert :ok = SessionEvents.subscribe("ws-ev-2", "sid-a")
    assert :ok = SessionEvents.broadcast_output("ws-ev-2", "sid-b", 1)

    refute_receive {:terminal_session_event, _}, 100
  end

  test "drops events without a full session identity" do
    assert :ok = SessionEvents.subscribe("ws-ev-3", "sid-1")

    assert :ok = SessionEvents.broadcast_output(nil, "sid-1", 1)
    assert :ok = SessionEvents.broadcast_output("ws-ev-3", nil, 1)

    refute_receive {:terminal_session_event, _}, 100
  end
end
