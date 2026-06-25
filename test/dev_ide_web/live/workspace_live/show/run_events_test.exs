defmodule DevIdeWeb.WorkspaceLive.Show.RunEventsTest do
  use ExUnit.Case, async: true

  alias DevIdeWeb.WorkspaceLive.Show.RunEvents

  # Covers the pure handle_event clauses (flash + assign only). The
  # interactive-agent branch of "run:start" and the run_ledger:* clauses
  # delegate to Show.* (IO) and are exercised through the LiveView elsewhere.
  defp socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}, palette_open: true}, assigns)
    }
  end

  test "run:start on a non-interactive id closes the palette and flashes" do
    assert {:noreply, s2} = RunEvents.handle_event("run:start", %{"id" => "compile"}, socket())
    assert s2.assigns.palette_open == false
    assert s2.assigns.flash["info"] =~ "raw terminal"
  end

  test "workflow:hint flashes guidance and closes the palette" do
    assert {:noreply, s2} = RunEvents.handle_event("workflow:hint", %{}, socket())
    assert s2.assigns.palette_open == false
    assert s2.assigns.flash["info"] =~ "full command"
  end

  test "workflow:run flashes the retirement notice" do
    assert {:noreply, s2} = RunEvents.handle_event("workflow:run", %{}, socket())
    assert s2.assigns.palette_open == false
    assert s2.assigns.flash["info"] =~ "retired"
  end

  test "run:cancel is a no-op" do
    s = socket()
    assert {:noreply, ^s} = RunEvents.handle_event("run:cancel", %{}, s)
  end
end
