defmodule Casein.Agents.AgentEvents.OpenClarificationsTest do
  use ExUnit.Case, async: true

  alias Casein.Agents.AgentEvent
  alias Casein.Agents.AgentEvents.OpenClarifications

  @request "agent.clarification_requested"
  @resolved "agent.clarification_resolved"

  test "projects only the newest unresolved clarification per exact target before limiting" do
    older = event(@request, "task-a", "session-a", "%2", -3)
    newest = event(@request, "task-a", "session-a", "%2", -2)
    other = event(@request, "task-b", "session-b", "%3", -1)

    assert [^other, ^newest] =
             OpenClarifications.project([older, newest, other], @request, @resolved, 10)

    assert [^other] = OpenClarifications.project([older, newest, other], @request, @resolved, 1)
  end

  test "older open request stays reachable when a newer request on the same pane is resolved" do
    older = event(@request, "task-a", "session-a", "%2", -3)
    newest = event(@request, "task-a", "session-a", "%2", -2)
    other = event(@request, "task-b", "session-b", "%3", -1)
    resolution = resolution_of(newest, 0)

    open = OpenClarifications.project([older, newest, other, resolution], @request, @resolved, 10)
    open_ids = Enum.map(open, & &1.id)

    # H28: filter resolved BEFORE distinct — older open on the same pane stays
    # answerable when a newer same-pane request was resolved.
    assert older.id in open_ids
    refute newest.id in open_ids
    assert other.id in open_ids
    assert length(open) == 2
    assert [^other, ^older] = open
  end

  test "resolved newest request does not hide an older open request on the same pane" do
    older_open = event(@request, "task-a", "session-a", "%2", -5)
    mid_resolved = event(@request, "task-a", "session-a", "%2", -3)
    mid_resolution = resolution_of(mid_resolved, -2)
    newest_resolved = event(@request, "task-a", "session-a", "%2", -1)
    newest_resolution = resolution_of(newest_resolved, 0)

    assert [^older_open] =
             OpenClarifications.project(
               [older_open, mid_resolved, mid_resolution, newest_resolved, newest_resolution],
               @request,
               @resolved,
               10
             )
  end

  test "empty input and zero limit return empty" do
    assert [] = OpenClarifications.project([], @request, @resolved, 10)
    req = event(@request, "task-a", "session-a", "%2", 0)
    assert [] = OpenClarifications.project([req], @request, @resolved, 0)
  end

  test "resolution payload accepts atom request_event_id keys" do
    older = event(@request, "task-a", "session-a", "%2", -2)
    newest = event(@request, "task-a", "session-a", "%2", -1)

    resolution = %AgentEvent{
      id: Ecto.UUID.generate(),
      event_type: @resolved,
      agent_session_id: newest.agent_session_id,
      tmux_session_id: newest.tmux_session_id,
      pane_id: newest.pane_id,
      payload: %{request_event_id: newest.id},
      occurred_at: DateTime.utc_now(),
      inserted_at: DateTime.utc_now()
    }

    assert [^older] =
             OpenClarifications.project([older, newest, resolution], @request, @resolved, 10)
  end

  defp event(type, task_id, tmux_session, pane_id, seconds) do
    occurred_at = DateTime.add(DateTime.utc_now(), seconds, :second)

    %AgentEvent{
      id: Ecto.UUID.generate(),
      event_type: type,
      agent_session_id: task_id,
      tmux_session_id: tmux_session,
      pane_id: pane_id,
      payload: %{"request_id" => Ecto.UUID.generate(), "question" => "Bounded question"},
      occurred_at: occurred_at,
      inserted_at: occurred_at
    }
  end

  defp resolution_of(%AgentEvent{} = request, seconds) do
    occurred_at = DateTime.add(DateTime.utc_now(), seconds, :second)

    %AgentEvent{
      id: Ecto.UUID.generate(),
      event_type: @resolved,
      agent_session_id: request.agent_session_id,
      tmux_session_id: request.tmux_session_id,
      pane_id: request.pane_id,
      payload: %{"request_event_id" => request.id},
      occurred_at: occurred_at,
      inserted_at: occurred_at
    }
  end
end
