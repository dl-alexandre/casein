defmodule Casein.Agents.AgentEvents.ClarificationEctoAdapterTest do
  use Casein.DataCase, async: false

  alias Casein.Agents.AgentEvent
  alias Casein.Agents.AgentEvents.EctoAdapter

  test "projects only the newest unresolved clarification per exact target before limiting" do
    workspace_id = Ecto.UUID.generate()
    older = insert_request(workspace_id, "task-a", "session-a", "%2", -3)
    newest = insert_request(workspace_id, "task-a", "session-a", "%2", -2)
    other = insert_request(workspace_id, "task-b", "session-b", "%3", -1)
    insert_resolution(workspace_id, newest, 0)

    assert [^other] =
             EctoAdapter.list_open_clarifications(
               workspace_id,
               "agent.clarification_requested",
               "agent.clarification_resolved",
               limit: 1
             )

    assert [^other] =
             EctoAdapter.list_open_clarifications(
               workspace_id,
               "agent.clarification_requested",
               "agent.clarification_resolved",
               limit: 10
             )

    refute older.id in Enum.map(
             EctoAdapter.list_open_clarifications(
               workspace_id,
               "agent.clarification_requested",
               "agent.clarification_resolved",
               limit: 10
             ),
             & &1.id
           )
  end

  defp insert_request(workspace_id, task_id, tmux_session, pane_id, seconds) do
    insert_event(%{
      workspace_id: workspace_id,
      stream_id: "clarification:#{task_id}",
      source_event_id: Ecto.UUID.generate(),
      event_type: "agent.clarification_requested",
      agent_session_id: task_id,
      tmux_session_id: tmux_session,
      pane_id: pane_id,
      payload: %{"request_id" => Ecto.UUID.generate(), "question" => "Bounded question"},
      seconds: seconds
    })
  end

  defp insert_resolution(workspace_id, request, seconds) do
    insert_event(%{
      workspace_id: workspace_id,
      stream_id: request.stream_id,
      source_event_id: "resolved:#{request.id}",
      event_type: "agent.clarification_resolved",
      agent_session_id: request.agent_session_id,
      tmux_session_id: request.tmux_session_id,
      pane_id: request.pane_id,
      payload: %{"request_event_id" => request.id},
      seconds: seconds
    })
  end

  defp insert_event(attrs) do
    occurred_at = DateTime.add(DateTime.utc_now(), Map.fetch!(attrs, :seconds), :second)

    attrs =
      attrs
      |> Map.delete(:seconds)
      |> Map.merge(%{
        producer: "agent",
        ingress: "test",
        privacy_class: "metadata",
        occurred_at: occurred_at,
        inserted_at: occurred_at
      })

    %AgentEvent{}
    |> AgentEvent.changeset(attrs)
    |> Repo.insert!()
  end
end
