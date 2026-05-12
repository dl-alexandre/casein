defmodule DevIDE.Assignments.ReconcilerTest do
  use ExUnit.Case, async: false

  alias DevIDE.Assignments
  alias DevIDE.Assignments.Reconciler

  setup do
    Assignments.clear()

    on_exit(fn ->
      Assignments.clear()
    end)

    :ok
  end

  test "tick lists assignments without passing the timestamp as list opts" do
    {:ok, _assignment} = Assignments.create(%{workspace_id: "ws-reconciler"})

    assert {:noreply, %{interval_ms: 60_000}} =
             Reconciler.handle_info(:tick, %{interval_ms: 60_000})
  end
end
