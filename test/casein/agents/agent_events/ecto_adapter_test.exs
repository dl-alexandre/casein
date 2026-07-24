defmodule Casein.Agents.AgentEvents.EctoAdapterTest do
  use Casein.DataCase, async: false

  alias Casein.Agents.AgentEvents
  alias Casein.Agents.AgentEvents.EctoAdapter

  setup do
    previous = Application.get_env(:casein, :agent_events_adapter)
    Application.put_env(:casein, :agent_events_adapter, EctoAdapter)
    on_exit(fn -> Application.put_env(:casein, :agent_events_adapter, previous) end)
    :ok
  end

  test "persists, deduplicates, and filters by native agent session" do
    attrs = %{
      workspace_id: "ws-ecto-events",
      producer: "grok",
      ingress: "acp",
      agent_session_id: "grok-ecto-session",
      source_event_id: "native-1",
      event_type: "plan.updated",
      payload: %{schema_version: 1, step_count: 3}
    }

    assert {:ok, inserted, :inserted} = AgentEvents.append_runtime(attrs)

    assert {:ok, duplicate, :duplicate} =
             AgentEvents.append_runtime(%{attrs | ingress: "transcript"})

    assert duplicate.id == inserted.id

    assert [stored] =
             AgentEvents.list_for_session("ws-ecto-events", "grok-ecto-session")

    assert stored.id == inserted.id
    assert stored.payload["step_count"] == 3
  end

  test "replay uses insertion order even when source times arrive out of order" do
    now = DateTime.utc_now()

    assert {:ok, first, :inserted} =
             AgentEvents.append_runtime(%{
               workspace_id: "ws-ecto-replay",
               producer: "grok",
               ingress: "transcript",
               agent_session_id: "sess-ecto-replay",
               source_event_id: "late-source-time",
               event_type: "tool.completed",
               occurred_at: DateTime.add(now, 60, :second)
             })

    assert {:ok, second, :inserted} =
             AgentEvents.append_runtime(%{
               workspace_id: "ws-ecto-replay",
               producer: "grok",
               ingress: "transcript",
               agent_session_id: "sess-ecto-replay",
               source_event_id: "early-source-time",
               event_type: "tool.started",
               occurred_at: DateTime.add(now, -60, :second)
             })

    page = AgentEvents.replay("ws-ecto-replay", limit: 10)
    assert Enum.map(page.events, & &1.id) == [first.id, second.id]
  end
end
