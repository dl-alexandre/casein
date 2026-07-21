defmodule DevIdeWeb.WorkspaceLive.Show.ConnectEventsTest do
  use DevIDE.TestCase, async: true

  alias DevIdeWeb.WorkspaceLive.Show.ConnectEvents

  # Pure clauses only: connect:close and the toggle-to-close path.
  # SKIPPED (OrchestratorTokens/Repo): connect:load, connect:mint, connect:revoke,
  # and connect:toggle when opening (calls load_tokens → list_for_subject).

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}
  end

  test "connect:close clears drawer token/error assigns" do
    s =
      socket(%{
        connect_drawer_open: true,
        connect_new_token: "tok",
        connect_mcp_json: "{}",
        connect_error: "boom",
        connect_info: "minted"
      })

    assert {:noreply, s2} = ConnectEvents.handle_event("connect:close", %{}, s)
    assert s2.assigns.connect_drawer_open == false
    assert s2.assigns.connect_new_token == nil
    assert s2.assigns.connect_mcp_json == nil
    assert s2.assigns.connect_error == nil
    assert s2.assigns.connect_info == nil
  end

  test "connect:toggle closes an open drawer without loading tokens" do
    s =
      socket(%{
        connect_drawer_open: true,
        connect_error: "stale",
        connect_tokens: :sentinel
      })

    assert {:noreply, s2} = ConnectEvents.handle_event("connect:toggle", %{}, s)
    assert s2.assigns.connect_drawer_open == false
    assert s2.assigns.connect_error == nil
    # load_tokens is skipped on close — tokens assign is untouched.
    assert s2.assigns.connect_tokens == :sentinel
  end
end
