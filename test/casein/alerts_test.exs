defmodule Casein.AlertsTest do
  use ExUnit.Case, async: true

  alias Casein.Alerts
  alias Casein.Audit.Event

  describe "terminal.size_fight alert" do
    test "is alert-worthy and titled" do
      assert Alerts.alert?("terminal.size_fight")
      assert Alerts.title_for("terminal.size_fight") == "Terminal size conflict"
    end

    test "routes to the in-app drawer only, not OS/mobile push" do
      # It's an operator/platform signal, not an end-user run event — a device
      # push would be noise. Keep it drawer-scoped so the contract is explicit.
      %{channels: channels, severity: severity} = Alerts.definition_for("terminal.size_fight")
      assert channels == ["in_app"]
      assert severity == "warning"
    end

    test "builds a durable drawer notification deep-linked to the workspace" do
      event =
        Event.new(%{
          workspace_id: "ws-abc",
          action: "terminal.size_fight",
          target_type: "terminal_session",
          target_ref: "sid-1",
          reason: "another writer keeps resizing this terminal to 80x24 against 190x50",
          metadata: %{"streak" => 4, "session_id" => "sid-1"}
        })

      attrs = Alerts.notification_attrs_for(event, "user-1")

      assert attrs.type == "terminal_size_fight"
      assert attrs.workspace_id == "ws-abc"
      assert attrs.channels == ["in_app"]
      assert attrs.deep_link == "casein://session/ws-abc"
      assert attrs.body =~ "80x24"
      # Dedupe scoping so a flapping deploy collapses to one card per session.
      assert attrs.dedupe_key == "user-1:terminal_size_fight:ws-abc:sid-1"
    end
  end
end
