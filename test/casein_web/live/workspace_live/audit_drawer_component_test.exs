defmodule CaseinWeb.WorkspaceLive.AuditDrawerComponentTest do
  use Casein.TestCase, async: false

  import Phoenix.LiveViewTest

  alias Casein.Audit
  alias Casein.Signals.Context
  alias CaseinWeb.WorkspaceLive.AuditDrawerComponent

  defp config(overrides) do
    # Unique per call: Audit.emit_decision persists across tests in this
    # file, so a shared workspace id would leak events between tests.
    ws_id = "ws-audit-#{System.unique_integer([:positive])}"

    Map.merge(
      %{
        id: "audit-drawer",
        open: false,
        workspace: %{id: ws_id, name: ws_id, user: "u1"},
        current_user: %{id: "u1", username: "u1", role: :user}
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
      endpoint: CaseinWeb.Endpoint,
      view: CaseinWeb.WorkspaceLive.Show,
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
    test "denies an unauthenticated viewer" do
      unauthorized = socket(%{current_user: %{}})

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

  describe "handle_event/3 (causal chain)" do
    test "trace loads the correlation chain in causal order" do
      cid =
        Context.with_new(fn ->
          {:ok, _} = Audit.emit(%{action: "chain.first", workspace_id: "wtrace"})
          {:ok, _} = Audit.emit(%{action: "chain.second", workspace_id: "wtrace"})
          Context.current().trace_id
        end)

      {:noreply, socket} =
        AuditDrawerComponent.handle_event(
          "audit_drawer:trace",
          %{"correlation" => cid},
          socket()
        )

      assert socket.assigns.audit_trace.correlation_id == cid

      assert Enum.map(socket.assigns.audit_trace.events, & &1.action) ==
               ["chain.first", "chain.second"]
    end

    test "trace_close clears the chain" do
      seeded = socket()

      seeded = %{
        seeded
        | assigns: Map.put(seeded.assigns, :audit_trace, %{correlation_id: "x", events: []})
      }

      {:noreply, socket} =
        AuditDrawerComponent.handle_event("audit_drawer:trace_close", %{}, seeded)

      assert socket.assigns.audit_trace == nil
    end

    test "an unauthenticated viewer cannot trace" do
      unauthorized = socket(%{current_user: %{}})

      {:noreply, socket} =
        AuditDrawerComponent.handle_event(
          "audit_drawer:trace",
          %{"correlation" => "any"},
          unauthorized
        )

      assert %{action: :ui_event, verdict: :deny, reason: :forbidden} =
               socket.assigns.last_decision

      assert_received {:panel_flash, :error, "You do not have access to this workspace."}
    end
  end
end
