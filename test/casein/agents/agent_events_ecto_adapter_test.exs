defmodule Casein.Agents.AgentEvents.ClarificationEctoAdapterTest do
  use Casein.DataCase, async: false

  alias Casein.Agents.AgentEvent
  alias Casein.Agents.AgentEvents.EctoAdapter

  test "projects only the newest unresolved clarification per exact target before limiting" do
    workspace_id = Ecto.UUID.generate()
    _older = insert_request(workspace_id, "task-a", "session-a", "%2", -3)
    newest = insert_request(workspace_id, "task-a", "session-a", "%2", -2)
    other = insert_request(workspace_id, "task-b", "session-b", "%3", -1)

    assert [^other, ^newest] =
             EctoAdapter.list_open_clarifications(
               workspace_id,
               "agent.clarification_requested",
               "agent.clarification_resolved",
               limit: 10
             )

    assert [^other] =
             EctoAdapter.list_open_clarifications(
               workspace_id,
               "agent.clarification_requested",
               "agent.clarification_resolved",
               limit: 1
             )
  end

  test "older open request stays reachable when a newer request on the same pane is resolved" do
    workspace_id = Ecto.UUID.generate()
    older = insert_request(workspace_id, "task-a", "session-a", "%2", -3)
    newest = insert_request(workspace_id, "task-a", "session-a", "%2", -2)
    other = insert_request(workspace_id, "task-b", "session-b", "%3", -1)
    insert_resolution(workspace_id, newest, 0)

    open =
      EctoAdapter.list_open_clarifications(
        workspace_id,
        "agent.clarification_requested",
        "agent.clarification_resolved",
        limit: 10
      )

    open_ids = Enum.map(open, & &1.id)
    # Filter resolved BEFORE distinct: older open on the same pane stays answerable
    # when a newer same-pane request was resolved (H28 mobile trap).
    assert older.id in open_ids
    refute newest.id in open_ids
    assert other.id in open_ids
    assert length(open) == 2
    assert [^other, ^older] = open
  end

  test "resolved newest request does not hide an older open request on the same pane" do
    workspace_id = Ecto.UUID.generate()
    older_open = insert_request(workspace_id, "task-a", "session-a", "%2", -5)
    mid_resolved = insert_request(workspace_id, "task-a", "session-a", "%2", -3)
    insert_resolution(workspace_id, mid_resolved, -2)
    newest_resolved = insert_request(workspace_id, "task-a", "session-a", "%2", -1)
    insert_resolution(workspace_id, newest_resolved, 0)

    assert [^older_open] =
             EctoAdapter.list_open_clarifications(
               workspace_id,
               "agent.clarification_requested",
               "agent.clarification_resolved",
               limit: 10
             )
  end

  test "windows desktop sqlite path uses shared H28 projector without postgres fragments" do
    # Desktop packages compile with CASEIN_REPO_ADAPTER=sqlite. The Ecto adapter
    # must not hard-code Postgres-only payload->>'…' / DISTINCT ON on that path;
    # OpenClarifications is the portable projector both SQLite Ecto and Memory use.
    source =
      File.read!(Path.expand("../../../lib/casein/agents/agent_events/ecto_adapter.ex", __DIR__))

    assert source =~ "if Casein.Repo.Adapter.sqlite?()"
    assert source =~ "OpenClarifications.project"
    assert source =~ "CASEIN_REPO_ADAPTER=sqlite"
    # Postgres branch retains the filter-before-distinct SQL contract.
    assert source =~ "?->>'request_event_id' = (?::text)"
    assert source =~ "not exists(subquery(resolved))"
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
