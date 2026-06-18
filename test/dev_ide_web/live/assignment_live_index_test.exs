defmodule DevIdeWeb.AssignmentLiveIndexTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Assignments
  alias DevIDE.Fleet

  setup do
    Fleet.clear()
    DevIDE.Fleet.Queue.clear()
    DevIDE.Fleet.RunnerDirectory.clear()
    Assignments.clear()

    on_exit(fn ->
      Fleet.clear()
      DevIDE.Fleet.Queue.clear()
      DevIDE.Fleet.RunnerDirectory.clear()
      Assignments.clear()
    end)

    :ok
  end

  test "renders the disconnected and connected index without crashing", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/assignments")

    assert html =~ "Assignments"
    assert html =~ ~s(name="state")
    assert has_element?(view, "select[name=\"state\"]")
  end

  test "renders with assignments present", %{conn: conn} do
    {:ok, _assignment} =
      Assignments.create(%{
        workspace_id: "ws-assignment-index",
        metadata: %{safe_action_id: "command:format", command_id: "format"}
      })

    {:ok, _view, html} = live(conn, ~p"/assignments")

    assert html =~ "Assignments"
    assert html =~ "ws-assignment-index"
  end
end
