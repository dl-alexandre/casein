defmodule CaseinWeb.WorkspaceLive.Show.WorkspacePolicyEventsTest do
  # Policy.gate → Audit.MemoryAdapter on deny/invalid-mode branches.
  use Casein.TestCase, async: false

  alias CaseinWeb.WorkspaceLive.Show.WorkspacePolicyEvents

  # Pure-ish deny / invalid branches that never call Workspaces.start/stop/set_mode.
  # SKIPPED (Workspaces manager HTTP / State mutations): workspace:start, workspace:stop,
  # allowed set_mode success paths.

  defp socket(assigns) do
    ws_id = "ws-policy-#{System.unique_integer([:positive])}"

    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            flash: %{},
            workspace: %{id: ws_id, user: "owner"},
            workspace_mode: :review,
            workspace_mode_source: :persisted,
            current_user: nil,
            db_isolation: %{}
          },
          assigns
        )
    }
  end

  test "workspace:set_mode denies an unauthenticated actor" do
    s = socket(%{current_user: nil})

    assert {:noreply, s2} =
             WorkspacePolicyEvents.handle_event(
               "workspace:set_mode",
               %{"mode" => "manual"},
               s
             )

    assert s2.assigns.flash["error"] == "Only the workspace owner can change mode."
    assert s2.assigns.last_decision.reason == :forbidden
  end

  test "workspace:set_mode denies when mode is pinned by configuration" do
    s =
      socket(%{
        current_user: %{id: "u1", username: "u1"},
        workspace_mode_source: :config
      })

    assert {:noreply, s2} =
             WorkspacePolicyEvents.handle_event(
               "workspace:set_mode",
               %{"mode" => "manual"},
               s
             )

    assert s2.assigns.flash["error"] == "Workspace mode is pinned by configuration."
    assert s2.assigns.last_decision.reason == :config_override
  end

  test "workspace:set_mode with an allowed actor ignores an unknown mode string" do
    s =
      socket(%{
        current_user: %{id: "u1", username: "u1"},
        workspace_mode: :review,
        workspace_mode_source: :persisted
      })

    assert {:noreply, s2} =
             WorkspacePolicyEvents.handle_event(
               "workspace:set_mode",
               %{"mode" => "not-a-mode"},
               s
             )

    # Policy allowed, string_to_mode returned nil → no-op beyond last_decision.
    assert Casein.Policy.Decision.allow?(s2.assigns.last_decision)
    assert s2.assigns.workspace_mode == :review
    assert s2.assigns.flash == %{}
  end
end
