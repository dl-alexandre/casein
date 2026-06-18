defmodule DevIDE.Fleet.OperatorNotificationsTest do
  use ExUnit.Case, async: false

  alias DevIDE.Fleet.OperatorNotifications

  setup do
    OperatorNotifications.clear()
    on_exit(fn -> OperatorNotifications.clear() end)
    :ok
  end

  test "list/1 filters by workspace_id when provided" do
    {:ok, alpha_failed} =
      OperatorNotifications.emit(:failed, %{
        workspace_id: "ws-alpha",
        assignment_id: "asgn-alpha",
        message: "alpha failed"
      })

    {:ok, beta_completed} =
      OperatorNotifications.emit(:completed, %{
        workspace_id: "ws-beta",
        assignment_id: "asgn-beta",
        message: "beta completed"
      })

    assert OperatorNotifications.list(limit: 10) == [beta_completed, alpha_failed]

    assert OperatorNotifications.list(workspace_id: "ws-alpha", limit: 10) == [alpha_failed]
    assert OperatorNotifications.list(workspace_id: "ws-beta", limit: 10) == [beta_completed]
    assert OperatorNotifications.list(workspace_id: "ws-missing", limit: 10) == []
  end
end
