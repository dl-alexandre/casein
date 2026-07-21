defmodule DevIdeWeb.WorkspaceLive.Show.SituationEventsTest do
  use DevIDE.TestCase, async: true

  alias DevIdeWeb.WorkspaceLive.Show.SituationEvents

  # Pure: situation_drawer:toggle / close, plus handle_info(:situation_seed) and
  # handle_info({:situation_risk, _, _}) when no SituationServer is registered
  # for the workspace (unique id => whereis nil => refresh_risks assigns
  # situation_enabled false and situation_risks []).

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}
  end

  test "situation_drawer:toggle flips situation_drawer_open" do
    s = socket(%{situation_drawer_open: false})
    assert {:noreply, s2} = SituationEvents.handle_event("situation_drawer:toggle", %{}, s)
    assert s2.assigns.situation_drawer_open == true

    assert {:noreply, s3} = SituationEvents.handle_event("situation_drawer:toggle", %{}, s2)
    assert s3.assigns.situation_drawer_open == false
  end

  test "situation_drawer:close forces the drawer closed" do
    s = socket(%{situation_drawer_open: true})
    assert {:noreply, s2} = SituationEvents.handle_event("situation_drawer:close", %{}, s)
    assert s2.assigns.situation_drawer_open == false

    assert {:noreply, s3} = SituationEvents.handle_event("situation_drawer:close", %{}, s2)
    assert s3.assigns.situation_drawer_open == false
  end

  test "handle_info(:situation_seed) with no server clears risks and disables badge" do
    workspace_id = "ws-situation-#{System.unique_integer([:positive])}"

    s =
      socket(%{
        workspace: %{id: workspace_id},
        situation_enabled: true,
        situation_risks: [%{id: "stale"}]
      })

    assert {:noreply, s2} = SituationEvents.handle_info(:situation_seed, s)
    assert s2.assigns.situation_enabled == false
    assert s2.assigns.situation_risks == []
  end

  test "handle_info({:situation_risk, :raise, _}) with no server clears risks and disables badge" do
    workspace_id = "ws-situation-#{System.unique_integer([:positive])}"

    s =
      socket(%{
        workspace: %{id: workspace_id},
        situation_enabled: true,
        situation_risks: [%{id: "stale"}]
      })

    assert {:noreply, s2} =
             SituationEvents.handle_info({:situation_risk, :raise, %{}}, s)

    assert s2.assigns.situation_enabled == false
    assert s2.assigns.situation_risks == []
  end
end
