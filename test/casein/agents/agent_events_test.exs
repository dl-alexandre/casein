defmodule Casein.Agents.AgentEventsTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.AgentEvents

  setup do
    AgentEvents.clear()
    on_exit(fn -> AgentEvents.clear() end)
    :ok
  end

  test "deduplicates a native event replayed through another ingress" do
    base = %{
      workspace_id: "ws-events",
      producer: "grok",
      agent_session_id: "grok-session-1",
      source_event_id: "native-event-7",
      event_type: "tool.started",
      status: "in_progress",
      summary: "Tool started",
      payload: %{schema_version: 1, tool_call_id: "tool-1"}
    }

    assert {:ok, inserted, :inserted} =
             AgentEvents.append_runtime(Map.put(base, :ingress, "acp"))

    assert {:ok, duplicate, :duplicate} =
             AgentEvents.append_runtime(Map.put(base, :ingress, "transcript"))

    assert duplicate.id == inserted.id
    assert duplicate.ingress == "acp"
    assert [stored] = AgentEvents.recent_for("ws-events")
    assert stored.stream_id == "grok:grok-session-1"
    assert stored.source_event_id == "native-event-7"
  end

  test "constructors retain metadata while excluding commands, transcript text, and state messages" do
    assert {:ok, mcp, :inserted} =
             AgentEvents.append_mcp(
               "ws-private",
               "terminal_mcp",
               %{
                 tool: "terminal_send_command",
                 session: "casein_ws_u-dev",
                 pane: "%3",
                 command: "cat private_key",
                 keys: "secret"
               },
               :ok
             )

    assert mcp.payload == %{"schema_version" => 1, "tool" => "terminal_send_command"}
    refute inspect(mcp) =~ "private_key"
    refute inspect(mcp) =~ "secret"

    assert [{:ok, transcript, :inserted}] =
             AgentEvents.append_transcript_entries(
               "ws-private",
               %{producer: "grok", agent_session_id: "sess-private"},
               [
                 %{
                   role: "assistant",
                   text: "proprietary source code",
                   cursor: "event-2",
                   tool_calls: [%{name: "Read", input_summary: "secret.ex"}]
                 }
               ]
             )

    assert transcript.payload["text_present"] == true
    assert transcript.payload["tool_names"] == ["Read"]
    refute inspect(transcript) =~ "proprietary source code"
    refute inspect(transcript) =~ "secret.ex"

    assert {:ok, transition, :inserted} =
             AgentEvents.append_state_transition(%{
               workspace_id: "ws-private",
               tmux_session_id: "casein_ws_u-dev",
               pane_id: "%3",
               state: :blocked,
               message: "credential copied into prompt"
             })

    assert transition.payload["message_present"] == true
    refute inspect(transition) =~ "credential copied"
  end

  test "replay resumes in insertion order with an opaque cursor" do
    for id <- ["one", "two", "three"] do
      assert {:ok, _event, :inserted} =
               AgentEvents.append_runtime(%{
                 workspace_id: "ws-replay",
                 producer: "grok",
                 ingress: "acp",
                 agent_session_id: "sess-replay",
                 source_event_id: id,
                 event_type: "plan.updated",
                 summary: id
               })
    end

    first = AgentEvents.replay("ws-replay", limit: 2)
    assert Enum.map(first.events, & &1.summary) == ["one", "two"]
    assert is_binary(first.cursor)

    second = AgentEvents.replay("ws-replay", after: first.cursor, limit: 2)
    assert Enum.map(second.events, & &1.summary) == ["three"]
  end

  test "causality is stored in columns and preserved in the Jido envelope" do
    event =
      Casein.Signals.Context.with_new(fn ->
        assert {:ok, event, :inserted} =
                 AgentEvents.append_runtime(%{
                   workspace_id: "ws-trace",
                   producer: "grok",
                   ingress: "acp",
                   agent_session_id: "grok-trace-session",
                   source_event_id: "trace-1",
                   event_type: "permission.requested"
                 })

        event
      end)

    assert is_binary(event.correlation_id)
    assert event.payload["correlation_id"] == event.correlation_id

    signal = Casein.Signals.from_agent_event(event)
    assert signal.id == event.id
    assert signal.data.agent_session_id == "grok-trace-session"
    assert signal.data.event_type == "permission.requested"
    assert signal.data.payload["correlation_id"] == event.correlation_id
  end
end
