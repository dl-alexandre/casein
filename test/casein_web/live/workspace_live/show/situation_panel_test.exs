defmodule CaseinWeb.WorkspaceLive.Show.SituationPanelTest do
  use Casein.TestCase, async: true

  import Phoenix.LiveViewTest

  alias CaseinWeb.WorkspaceLive.Show.SituationPanel

  defp risk(id, severity, subject) do
    %{
      id: id,
      severity: severity,
      subject: subject,
      detected_at: ~U[2026-07-16 12:00:00Z],
      evidence: %{},
      suggestion: "do the thing"
    }
  end

  describe "situation_badge/1" do
    test "renders nothing when disabled" do
      html = render_component(&SituationPanel.situation_badge/1, enabled: false, risks: [])
      refute html =~ "situation-badge"
    end

    test "shows the count and colors by max severity" do
      risks = [risk(:agent_blocked, :warn, "a %1"), risk(:deploy_gate_failed, :critical, "rev")]
      html = render_component(&SituationPanel.situation_badge/1, enabled: true, risks: risks)

      assert html =~ "situation-badge"
      assert html =~ "2 risks"
      assert html =~ "bg-status-danger-soft"
    end

    test "an empty active set renders a neutral zero badge" do
      html = render_component(&SituationPanel.situation_badge/1, enabled: true, risks: [])
      assert html =~ "0 risks"
      refute html =~ "bg-status-danger-soft"
    end
  end

  describe "situation_drawer/1" do
    test "renders nothing when closed or disabled" do
      refute render_component(&SituationPanel.situation_drawer/1,
               enabled: true,
               open: false,
               risks: [],
               workspace: %{name: "ws"}
             ) =~ "Situation risks"

      refute render_component(&SituationPanel.situation_drawer/1,
               enabled: false,
               open: true,
               risks: [],
               workspace: %{name: "ws"}
             ) =~ "Situation risks"
    end

    test "lists active risks with subject and suggestion" do
      html =
        render_component(&SituationPanel.situation_drawer/1,
          enabled: true,
          open: true,
          risks: [risk(:blocked_too_long, :critical, "casein_a_agent %1")],
          workspace: %{name: "ws-panel"}
        )

      assert html =~ "Situation risks"
      assert html =~ "1 active"
      assert html =~ "blocked_too_long"
      assert html =~ "casein_a_agent %1"
      assert html =~ "do the thing"
    end
  end
end
