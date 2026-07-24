defmodule Casein.Codex.EventTest do
  use ExUnit.Case, async: true

  alias Casein.Codex.Event

  test "builds a versioned event with stable runtime ordering" do
    occurred_at = ~U[2026-07-15 22:00:00Z]

    event =
      Event.new!(
        :turn_started,
        %{
          workspace_id: "ws-1",
          runtime_id: "runtime-1",
          transport: :app_server,
          sequence: 7,
          occurred_at: occurred_at
        },
        thread_id: "thread-1",
        turn_id: "turn-1",
        payload: %{status: :in_progress},
        metadata: %{codex_method: "turn/started"}
      )

    assert event.schema_version == 1
    assert event.sequence == 7
    assert event.occurred_at == occurred_at
    assert event.thread_id == "thread-1"
    assert event.turn_id == "turn-1"
    assert event.transport == :app_server
    assert Ecto.UUID.cast(event.id) == {:ok, event.id}
  end

  test "rejects invalid trusted context" do
    assert_raise ArgumentError, fn ->
      Event.new!(:turn_started, %{
        workspace_id: "ws-1",
        runtime_id: "runtime-1",
        transport: :unknown,
        sequence: 0
      })
    end
  end
end
