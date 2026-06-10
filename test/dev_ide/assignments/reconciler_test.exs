defmodule DevIDE.Assignments.ReconcilerTest do
  use ExUnit.Case, async: false

  alias DevIDE.Assignments
  alias DevIDE.Assignments.Reconciler

  setup do
    prev_stale_threshold = Application.get_env(:dev_ide, :assignment_stale_threshold_ms)
    Assignments.clear()

    on_exit(fn ->
      Assignments.clear()
      restore_env(:assignment_stale_threshold_ms, prev_stale_threshold)
    end)

    :ok
  end

  test "tick lists assignments without passing the timestamp as list opts" do
    {:ok, _assignment} = Assignments.create(%{workspace_id: "ws-reconciler"})

    assert {:noreply, %{interval_ms: 60_000}} =
             Reconciler.handle_info(:tick, %{interval_ms: 60_000})
  end

  test "tick expires elapsed leases and abandons stale claimed assignments" do
    Application.put_env(:dev_ide, :assignment_stale_threshold_ms, 0)

    {:ok, expired} = Assignments.create(%{workspace_id: "ws-reconciler"})
    {:ok, _claimed} = Assignments.claim(expired.id, "runner-expired", lease_ms: -1)

    {:ok, stale} = Assignments.create(%{workspace_id: "ws-reconciler"})
    {:ok, _claimed} = Assignments.claim(stale.id, "runner-stale", lease_ms: 60_000)

    assert {:noreply, %{interval_ms: 60_000}} =
             Reconciler.handle_info(:tick, %{interval_ms: 60_000})

    assert {:ok, expired_projection} = Assignments.get(expired.id)
    assert expired_projection.state == "expired"
    assert expired_projection.failure_reason == "lease_expired"

    assert {:ok, stale_projection} = Assignments.get(stale.id)
    assert stale_projection.state == "abandoned"
    assert stale_projection.failure_reason == "stale_recovery"
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
