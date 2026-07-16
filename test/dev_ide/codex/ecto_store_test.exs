defmodule DevIDE.Codex.EctoStoreTest do
  use DevIDE.DataCase, async: false

  alias DevIDE.Codex.Event
  alias DevIDE.Codex.Store.EctoAdapter

  test "persists canonical events and rebuilds query projections" do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    workspace_id = "ws-ecto-" <> suffix
    runtime_id = "runtime-ecto-" <> suffix
    thread_id = "thread-ecto-" <> suffix

    event =
      Event.new!(
        :thread_started,
        %{
          workspace_id: workspace_id,
          runtime_id: runtime_id,
          transport: :exec,
          sequence: 1,
          occurred_at: ~U[2026-07-16 09:10:00Z]
        },
        thread_id: thread_id,
        payload: %{status: :active, preview: "Reviewing changes"}
      )

    assert :ok = EctoAdapter.record(event)
    assert EctoAdapter.latest_sequence(runtime_id) == 1

    assert %{threads: [%{thread_id: ^thread_id, transport: :exec}], approvals: []} =
             EctoAdapter.workspace_snapshot(workspace_id, [])

    assert [%Event{id: id, type: :thread_started}] =
             EctoAdapter.timeline(workspace_id, thread_id, [])

    assert id == event.id
  end
end
