defmodule DevIdeWeb.WorkspaceLive.ProposalPanelComponentTest do
  use DevIDE.TestCase, async: false

  import Phoenix.LiveViewTest

  alias DevIdeWeb.WorkspaceLive.ProposalPanelComponent

  setup do
    root = Path.join(System.tmp_dir!(), "proposal-panel-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp admin_user, do: %{id: "u1", username: "u1", role: :admin}

  defp config(root, overrides \\ %{}) do
    Map.merge(
      %{
        id: "proposal-panel",
        workspace: %{id: "ws-proposals", user: "u1"},
        current_user: admin_user(),
        workspace_mode_source: nil,
        db_isolation: %{},
        host_path: {:ok, root}
      },
      overrides
    )
  end

  defp socket(root, overrides \\ %{}) do
    %Phoenix.LiveView.Socket{
      endpoint: DevIdeWeb.Endpoint,
      view: DevIdeWeb.WorkspaceLive.Show,
      root_pid: self(),
      private: %{live_temp: %{}},
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            proposals: [],
            proposal_selected: nil,
            proposal_analysis: nil,
            proposal_pending_confirm: nil,
            proposal_error: nil,
            flash: %{}
          },
          Map.merge(config(root), overrides)
        )
    }
  end

  describe "update/render" do
    test "renders the empty state and loads proposals from the workspace root", %{root: root} do
      html = render_component(ProposalPanelComponent, config(root))

      assert html =~ "No proposal diffs found."
      assert html =~ "Select a proposal to review its diff."
    end

    test "renders without proposals when the host path is unavailable", %{root: _root} do
      html =
        render_component(
          ProposalPanelComponent,
          config("/nonexistent", %{host_path: {:error, :not_set}})
        )

      assert html =~ "No proposal diffs found."
    end
  end

  describe "handle_event/3 (authorized)" do
    test "proposal:refresh reloads the proposal list", %{root: root} do
      {:noreply, socket} =
        ProposalPanelComponent.handle_event("proposal:refresh", %{}, socket(root))

      assert socket.assigns.proposals == []
    end

    test "proposal:apply_cancel clears the pending confirmation", %{root: root} do
      {:noreply, socket} =
        ProposalPanelComponent.handle_event(
          "proposal:apply_cancel",
          %{},
          socket(root, %{proposal_pending_confirm: "some/path.diff"})
        )

      assert socket.assigns.proposal_pending_confirm == nil
    end

    test "proposal:select surfaces a missing path as an invalid proposal", %{root: root} do
      {:noreply, socket} =
        ProposalPanelComponent.handle_event(
          "proposal:select",
          %{"path" => "missing.diff"},
          socket(root)
        )

      assert %{status: :invalid, rel_path: "missing.diff"} = socket.assigns.proposal_selected
      assert socket.assigns.proposal_error == nil
    end
  end

  describe "handle_event/3 (viewer gate)" do
    # Component events bypass Show's authz hook; PanelGate must fail closed
    # with the same audited denial for a non-owner, non-admin viewer.
    test "denies an unauthorized viewer and asks the parent LV to flash", %{root: root} do
      unauthorized = socket(root, %{current_user: %{id: "intruder", username: "intruder"}})

      {:noreply, socket} =
        ProposalPanelComponent.handle_event("proposal:refresh", %{}, unauthorized)

      assert %{action: :ui_event, verdict: :deny, reason: :forbidden} =
               socket.assigns.last_decision

      assert_received {:panel_flash, :error, "You do not have access to this workspace."}
    end

    test "does not deny the workspace owner", %{root: root} do
      owner = socket(root, %{current_user: %{id: "u1", username: "u1"}})

      {:noreply, socket} = ProposalPanelComponent.handle_event("proposal:refresh", %{}, owner)

      refute Map.get(socket.assigns, :last_decision)
      refute_received {:panel_flash, _, _}
    end
  end
end
