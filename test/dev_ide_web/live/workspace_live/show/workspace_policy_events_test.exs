defmodule DevIdeWeb.WorkspaceLive.Show.WorkspacePolicyEventsTest do
  # Policy.gate → Audit.MemoryAdapter on deny/invalid-mode branches.
  use DevIDE.TestCase, async: false

  alias DevIdeWeb.WorkspaceLive.Show.WorkspacePolicyEvents

  # Pure-ish deny / invalid branches that never call Workspaces.start/stop/set_mode.
  # SKIPPED (Workspaces manager HTTP / State mutations): workspace:start, workspace:stop,
  # allowed set_mode/grant/revoke success paths.

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
    assert DevIDE.Policy.Decision.allow?(s2.assigns.last_decision)
    assert s2.assigns.workspace_mode == :review
    assert s2.assigns.flash == %{}
  end

  test "workspace:grant_agent_write_unlock denies an unauthenticated actor" do
    s = socket(%{current_user: nil})

    assert {:noreply, s2} =
             WorkspacePolicyEvents.handle_event(
               "workspace:grant_agent_write_unlock",
               %{"minutes" => "30"},
               s
             )

    assert s2.assigns.flash["error"] == "Only the workspace owner can grant agent write."
    assert s2.assigns.last_decision.reason == :forbidden
  end

  test "workspace:grant_agent_write_unlock denies when config-pinned" do
    s =
      socket(%{
        current_user: %{id: "u1", username: "u1"},
        workspace_mode_source: :config,
        workspace_mode: :manual
      })

    assert {:noreply, s2} =
             WorkspacePolicyEvents.handle_event(
               "workspace:grant_agent_write_unlock",
               %{"minutes" => "30"},
               s
             )

    assert s2.assigns.flash["error"] == "Workspace mode is pinned by configuration."
  end

  test "workspace:grant_agent_write_unlock denies outside manual mode" do
    ws_id = "ws-policy-#{System.unique_integer([:positive])}"
    assert {:ok, _} = DevIDE.Workspaces.State.set_mode(ws_id, :review)

    s =
      socket(%{
        workspace: %{id: ws_id, user: "owner"},
        current_user: %{id: "u1", username: "u1"},
        workspace_mode: :review,
        workspace_mode_source: :persisted
      })

    assert {:noreply, s2} =
             WorkspacePolicyEvents.handle_event(
               "workspace:grant_agent_write_unlock",
               %{"minutes" => "30"},
               s
             )

    assert s2.assigns.flash["error"] == "Agent write unlock requires manual mode."
    assert s2.assigns.last_decision.reason == :requires_manual_mode
  end

  test "workspace:revoke_agent_write_unlock denies an unauthenticated actor" do
    s = socket(%{current_user: nil})

    assert {:noreply, s2} =
             WorkspacePolicyEvents.handle_event(
               "workspace:revoke_agent_write_unlock",
               %{},
               s
             )

    assert s2.assigns.flash["error"] == "Not allowed to revoke."
    assert s2.assigns.last_decision.reason == :forbidden
  end
end
