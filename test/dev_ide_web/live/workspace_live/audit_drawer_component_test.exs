defmodule DevIdeWeb.WorkspaceLive.AuditDrawerComponentTest do
  use DevIDE.TestCase, async: false

  import Phoenix.LiveViewTest

  alias DevIdeWeb.WorkspaceLive.AuditDrawerComponent

  defp config(overrides) do
    # Unique per call: Audit.emit_decision persists across tests in this
    # file, so a shared workspace id would leak events between tests.
    ws_id = "ws-audit-#{System.unique_integer([:positive])}"

    Map.merge(
      %{
        id: "audit-drawer",
        open: false,
        workspace: %{id: ws_id, name: ws_id, user: "u1"},
        current_user: %{id: "u1", username: "u1", role: :admin}
      },
      Map.new(overrides)
    )
  end

  defp socket(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          __changed__: %{},
          audit_window_filter: "",
          audit_events_count: 0,
          audit_deny_count: 0,
          audit_ledger_count: 0,
          flash: %{},
          # A CID marks this as a LiveComponent socket so stream/3 takes the
          # component path instead of attaching a LiveView lifecycle hook.
          myself: %Phoenix.LiveComponent.CID{cid: 1}
        },
        config(overrides)
      )

    %Phoenix.LiveView.Socket{
      endpoint: DevIdeWeb.Endpoint,
      view: DevIdeWeb.WorkspaceLive.Show,
      root_pid: self(),
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}},
      assigns: assigns
    }
    |> Phoenix.LiveView.stream(:audit_events, [])
  end

  describe "update/render" do
    test "renders nothing visible while closed" do
      html = render_component(AuditDrawerComponent, config(open: false))

      refute html =~ "Evidence"
    end

    test "renders the drawer with counts when open" do
      html = render_component(AuditDrawerComponent, config(open: true))

      assert html =~ "Evidence"
      assert html =~ "0 events · 0 ledger"
      assert html =~ "audit-window-filter"
    end
  end

  describe "handle_event/3 (viewer gate)" do
    test "denies an unauthorized viewer" do
      unauthorized = socket(%{current_user: %{id: "intruder", username: "intruder"}})

      {:noreply, socket} =
        AuditDrawerComponent.handle_event("audit_drawer:refresh", %{}, unauthorized)

      assert %{action: :ui_event, verdict: :deny, reason: :forbidden} =
               socket.assigns.last_decision

      assert_received {:panel_flash, :error, "You do not have access to this workspace."}
    end

    test "filter_window updates the filter for an authorized viewer" do
      {:noreply, socket} =
        AuditDrawerComponent.handle_event(
          "audit_drawer:filter_window",
          %{"filter" => "  main  "},
          socket()
        )

      assert socket.assigns.audit_window_filter == "main"
      refute_received {:panel_flash, _, _}
    end
  end
end
