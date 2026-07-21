defmodule DevIdeWeb.WorkspaceLive.Show.SituationEventsTest do
  use DevIDE.TestCase, async: true

  alias DevIdeWeb.WorkspaceLive.Show.SituationEvents

  # Pure: situation_drawer:toggle / close.
  # SKIPPED (SituationServer registry/PubSub): mount/1, handle_info(:situation_seed),
  # handle_info({:situation_risk, _, _}) — they call whereis/active_risks/subscribe.

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
end
