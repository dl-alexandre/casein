defmodule Casein.Runtimes.StateMachineTest do
  use Casein.TestCase, async: true

  alias Casein.Runtimes.{LifecycleEvent, StateMachine}

  test "runtime lifecycle transitions are bounded to placement states" do
    assert StateMachine.statuses() == ~w(requested provisioned expired cleaned)

    assert {:ok, "requested"} = StateMachine.transition(nil, :request)
    assert {:ok, "provisioned"} = StateMachine.transition(nil, :provision)
    assert {:ok, "provisioned"} = StateMachine.transition("requested", :provision)
    assert {:ok, "expired"} = StateMachine.transition("provisioned", :expire)
    assert {:ok, "cleaned"} = StateMachine.transition("expired", :cleanup)
    assert {:ok, "provisioned"} = StateMachine.transition("expired", :restore)
    assert {:ok, "provisioned"} = StateMachine.transition("cleaned", :restore)

    # Direct expiry from requested (stale sweep before provisioning) is allowed.
    assert {:ok, "expired"} = StateMachine.transition("requested", :expire)

    assert {:error, :invalid_runtime_transition} =
             StateMachine.transition("requested", :cleanup)

    assert {:error, :runtime_terminal} = StateMachine.transition("cleaned", :expire)
  end

  test "restored lifecycle events replay from expired and cleaned states" do
    now = DateTime.utc_now()

    expired_restore = [
      event("runtime_requested", "requested", nil, now),
      event("runtime_provisioned", "provisioned", "requested", DateTime.add(now, 1)),
      event("runtime_expired", "expired", "provisioned", DateTime.add(now, 2)),
      event("runtime_restored", "provisioned", "expired", DateTime.add(now, 3))
    ]

    assert {:ok, "provisioned"} = StateMachine.reduce(expired_restore)

    cleaned_restore =
      List.insert_at(
        expired_restore,
        3,
        event("runtime_cleaned", "cleaned", "expired", DateTime.add(now, 3))
      )
      |> List.replace_at(
        4,
        event("runtime_restored", "provisioned", "cleaned", DateTime.add(now, 4))
      )

    assert {:ok, "provisioned"} = StateMachine.reduce(cleaned_restore)
  end

  test "append-only lifecycle events reduce to the projected status" do
    now = DateTime.utc_now()

    events = [
      event("runtime_requested", "requested", nil, now),
      event("runtime_provisioned", "provisioned", "requested", DateTime.add(now, 1)),
      event("runtime_expired", "expired", "provisioned", DateTime.add(now, 2)),
      event("runtime_cleaned", "cleaned", "expired", DateTime.add(now, 3))
    ]

    assert {:ok, "cleaned"} = StateMachine.reduce(events)
  end

  test "heartbeat and preview events are projection no-ops and unknown events fail reduction" do
    now = DateTime.utc_now()

    events = [
      event("runtime_requested", "requested", nil, now),
      event("runtime_heartbeat", "requested", "requested", DateTime.add(now, 1)),
      event("runtime_provisioned", "provisioned", "requested", DateTime.add(now, 2)),
      event("runtime_preview_starting", "provisioned", "provisioned", DateTime.add(now, 3)),
      event("runtime_preview_running", "provisioned", "provisioned", DateTime.add(now, 4)),
      event("runtime_preview_failed", "provisioned", "provisioned", DateTime.add(now, 5))
    ]

    assert {:ok, "provisioned"} = StateMachine.reduce(events)

    unknown = event("runtime_rehomed", "provisioned", "provisioned", DateTime.add(now, 6))
    assert {:error, :unknown_runtime_event} = StateMachine.reduce(events ++ [unknown])
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
