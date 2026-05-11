defmodule DevIDE.Runtimes.StateMachineTest do
  use ExUnit.Case, async: true

  alias DevIDE.Runtimes.{LifecycleEvent, StateMachine}

  test "runtime lifecycle transitions are bounded to placement states" do
    assert StateMachine.statuses() ==
             ~w(requested provisioned bound active idle expired failed cleaned)

    assert {:ok, "requested"} = StateMachine.transition(nil, :request)
    assert {:ok, "provisioned"} = StateMachine.transition("requested", :provision)
    assert {:ok, "bound"} = StateMachine.transition("provisioned", :bind)
    assert {:ok, "active"} = StateMachine.transition("bound", :activate)
    assert {:ok, "idle"} = StateMachine.transition("active", :idle)
    assert {:ok, "expired"} = StateMachine.transition("idle", :expire)
    assert {:ok, "cleaned"} = StateMachine.transition("expired", :cleanup)

    assert {:error, :invalid_runtime_transition} =
             StateMachine.transition("requested", :bind)

    assert {:error, :runtime_terminal} = StateMachine.transition("cleaned", :bind)
  end

  test "append-only lifecycle events reduce to the projected status" do
    now = DateTime.utc_now()

    events = [
      event("runtime_requested", "requested", nil, now),
      event("runtime_provisioned", "provisioned", "requested", DateTime.add(now, 1)),
      event("runtime_bound", "bound", "provisioned", DateTime.add(now, 2)),
      event("runtime_active", "active", "bound", DateTime.add(now, 3)),
      event("runtime_idle", "idle", "active", DateTime.add(now, 4)),
      event("runtime_expired", "expired", "idle", DateTime.add(now, 5)),
      event("runtime_cleaned", "cleaned", "expired", DateTime.add(now, 6))
    ]

    assert {:ok, "cleaned"} = StateMachine.reduce(events)
  end

  defp event(name, to_status, from_status, inserted_at) do
    %LifecycleEvent{
      id: Ecto.UUID.generate(),
      runtime_id: "rt-test",
      workspace_id: "ws-test",
      event: name,
      from_status: from_status,
      to_status: to_status,
      inserted_at: inserted_at
    }
  end
end
