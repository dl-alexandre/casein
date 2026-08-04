defmodule DevideMob.MobileDogfoodFlowTest do
  use Mob.ScreenCase, async: false

  alias DevideMob.PairingScreen
  alias DevideMob.SessionConfig
  alias DevideMob.SessionDashboardScreen
  alias DevideMob.SessionDetailScreen

  @workspace_id "mobile-dogfood-workspace"

  setup do
    SessionConfig.clear_all()
    :ok
  end

  test "first-run pairing through dashboard supervision and recovery" do
    dashboard = mount_screen(SessionDashboardScreen)

    assert_renderable(dashboard, extra: [:icon])
    assert text(dashboard) =~ "Not paired yet"

    pair_cta = find(dashboard, :button, text: "+ Pair workspace")
    assert {_pid, :pair_device} = pair_cta.props.on_tap

    dashboard = render_info(dashboard, {:tap, :pair_device})
    assert navigated_to(dashboard) == PairingScreen

    pairing =
      PairingScreen
      |> mount_screen()
      |> render_info(
        {:change, :code, pairing_code("https://devide.test", "token", @workspace_id)}
      )
      |> render_info({:tap, :pair})

    assert_renderable(pairing, extra: [:icon])
    assert text(pairing) =~ "Paired successfully"
    assert find(pairing, :button, text: "Continue")
    assert SessionConfig.pairing() == {:ok, "https://devide.test", "token"}
    assert SessionConfig.pinned_workspaces() == [@workspace_id]

    pairing = render_info(pairing, {:tap, :continue})
    assert navigated_to(pairing) == SessionDashboardScreen

    dashboard =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:session_snapshot, @workspace_id, active_snapshot()})
      |> render_info({:session_status, @workspace_id, :joined})
      |> render_info({:mobile_cards_status, :joined})
      |> render_info({:push_token, :android, "fcm-token"})

    assert assigns(dashboard).push_status == :registering
    assert assigns(dashboard).push_user_registration_pending? == true
    assert assigns(dashboard).push_user_registered? == false

    dashboard = render_info(dashboard, {:push_registration_status, :user, :registered})

    assert assigns(dashboard).push_status == :registered
    assert assigns(dashboard).push_user_registration_pending? == false
    assert assigns(dashboard).push_user_registered? == true

    dashboard = render_info(dashboard, {:push_registration_status, @workspace_id, :registered})

    assert MapSet.member?(assigns(dashboard).push_registered_workspace_ids, @workspace_id)

    assert_renderable(dashboard, extra: [:icon])
    assert text(dashboard) =~ "Live"
    assert text(dashboard) =~ "Running mix test"
    assert text(dashboard) =~ "1 agent active"

    assert find(dashboard, :text, text: "3 items need review")
    review_cta = find(dashboard, :box, on_tap: {self(), {:open, @workspace_id}})
    assert {_pid, {:open, @workspace_id}} = review_cta.props.on_tap

    dashboard = render_info(dashboard, {:tap, {:open, @workspace_id}})
    assert navigated_to(dashboard) == SessionDetailScreen

    detail =
      SessionDetailScreen
      |> mount_screen(%{workspace_id: @workspace_id})
      |> render_info({:session_snapshot, @workspace_id, active_snapshot()})
      |> render_info({:session_status, @workspace_id, :joined})

    assert_renderable(detail, extra: [:icon])
    assert text(detail) =~ "Workspace status"
    assert text(detail) =~ "Live"
    assert text(detail) =~ "Current run"
    assert text(detail) =~ "mix test"
    assert text(detail) =~ "Work log"
    assert text(detail) =~ "policy review required"
    assert text(detail) =~ "Active agents"
    assert text(detail) =~ "reviewer"

    detail = render_info(detail, {:tap, :back})
    assert navigated_to(detail) == {:pop}

    dashboard =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:session_snapshot, @workspace_id, active_snapshot()})
      |> render_info({:session_status, @workspace_id, :disconnected})

    assert text(dashboard) =~ "Last seen"
    offline_pill = find(dashboard, :button, text: "Offline")
    assert {_pid, {:retry, @workspace_id}} = offline_pill.props.on_tap

    dashboard = render_info(dashboard, {:tap, {:retry, @workspace_id}})
    assert assigns(dashboard).statuses[@workspace_id] == :connecting
    assert text(dashboard) =~ "Reconnecting mobile-dogfood-workspace..."

    dashboard = render_info(dashboard, {:tap, :unpair})
    assert SessionConfig.pairing() == :error
    assert SessionConfig.pinned_workspaces() == []
    assert text(dashboard) =~ "Not paired yet"
  end

  defp active_snapshot do
    %{
      "mode" => "review",
      "pending_reviews" => 3,
      "current_run" => %{
        "status" => "started",
        "command_id" => "mix test",
        "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      },
      "recent_audit" => [
        %{
          "action" => "mix test",
          "decision" => "deny",
          "reason" => "policy review required",
          "at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      ],
      "active_agents" => [
        %{"tool" => "reviewer", "summary" => "checking changes"}
      ],
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp pairing_code(url, token, workspace_id) do
    %{url: url, token: token, workspace_id: workspace_id, token_type: "mobile_pairing"}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end
end
