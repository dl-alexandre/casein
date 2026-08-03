defmodule CaseinMob.SessionDashboardScreenTest do
  use Mob.ScreenCase, async: false

  alias CaseinMob.ConnectionTiming
  alias CaseinMob.SessionClient
  alias CaseinMob.SessionConfig
  alias CaseinMob.SessionDashboardScreen

  setup do
    previous_dev_notification = System.get_env("CASEIN_MOB_DEV_NOTIFICATION_JSON")
    System.delete_env("CASEIN_MOB_DEV_NOTIFICATION_JSON")

    on_exit(fn ->
      restore_env("CASEIN_MOB_DEV_NOTIFICATION_JSON", previous_dev_notification)
    end)

    SessionConfig.clear_all()
    :ok
  end

  test "renders root header actions without back chrome" do
    view = mount_screen(SessionDashboardScreen)

    assert_renderable(view)
    assert text(view) =~ "Attention Inbox"
    assert find(view, :button, text: "+ Pair").props.fill_width == false
    assert find(view, :button, text: "...").props.fill_width == false
    assert find(view, :button, text: "...")
    refute find(view, :button, text: "Back")
    refute find(view, :button, text: "Home")
  end

  test "not paired empty state invites pairing" do
    view = mount_screen(SessionDashboardScreen)

    assert_renderable(view)
    assert_no_nil_children(tree(view))
    assert text(view) =~ "Not paired yet"
    assert text(view) =~ "Pair this phone with a workspace"
    assert find(view, :button, text: "+ Pair workspace")
  end

  test "native pairing deep link opens the pairing screen with its code" do
    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info(
        {:notification,
         %{
           "data" => %{
             "action" => "mobile.pair",
             "pairing_code" => "opaque-pairing-code",
             "deep_link" => "casein://pair/opaque-pairing-code"
           }
         }}
      )

    assert navigated_to(view) == CaseinMob.PairingScreen
  end

  test "paired empty state explains the missing workspace" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view = mount_screen(SessionDashboardScreen)

    assert_renderable(view)
    assert_no_nil_children(tree(view))
    assert text(view) =~ "casein.test · Connecting"
    assert text(view) =~ "Saved profile · validating live access"
    assert text(view) =~ "https://casein.test"
    assert text(view) =~ "Card stream connecting"
    assert text(view) =~ "No workspace pinned"
    assert text(view) =~ "Currently supports one workspace at a time."
    assert text(view) =~ "Push native_unavailable · token no · user no · workspaces 0"
    assert find(view, :button, text: "+ Pair workspace")
    assert find(view, :button, text: "Unpair")
  end

  test "paired dashboard offers to resume the last persisted session context" do
    SessionConfig.put_pairing("https://casein.test", "token")
    SessionConfig.put_resume_context("ws-1", session_id: "run-1", source: :review)

    view = mount_screen(SessionDashboardScreen)

    assert assigns(view).resume_context == %{
             workspace_id: "ws-1",
             session_id: "run-1",
             source: :review
           }

    assert find(view, :button, text: "Resume casein.test work").props.fill_width
    assert find(view, :button, text: "Unpair").props.fill_width == false

    view = render_info(view, {:tap, :resume_last_session})

    assert navigated_to(view) == CaseinMob.SessionDetailScreen

    assert SessionConfig.resume_context() == %{
             workspace_id: "ws-1",
             session_id: "run-1",
             source: :review
           }
  end

  test "saved host selector switches active origin and its scoped workspaces" do
    SessionConfig.put_pairing("http://192.168.1.72:57585", "mac-token")
    SessionConfig.pin_workspace("mac-ws")
    SessionConfig.put_pairing("https://casein.test", "devbox-token")
    SessionConfig.pin_workspace("devbox-ws")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:push_token, :ios, "devbox-apns-token"})
      |> render_info({:push_registration_status, "devbox-ws", :registered})

    assert text(view) =~ "Saved hosts"
    assert find(view, :button, text: "Switch to · Local Mac")
    assert find(view, :button, text: "Selected · casein.test")
    assert text(view) =~ "Last work: mac-ws"

    mac_origin_id = CaseinMob.OriginIdentity.legacy_id("http://192.168.1.72:57585")
    view = render_info(view, {:tap, {:switch_host, mac_origin_id}})

    assert SessionConfig.pairing() ==
             {:ok, "http://192.168.1.72:57585", "mac-token"}

    assert assigns(view).pinned == ["mac-ws"]
    assert assigns(view).push_token == nil
    assert assigns(view).push_registered_workspace_ids == MapSet.new()
    assert text(view) =~ "Switched origin; refreshing authoritative state"
    assert find(view, :button, text: "Selected · Local Mac")

    view =
      render_info(
        view,
        {:mobile_cards_snapshot,
         %{
           "origin" => %{"id" => mac_origin_id, "display_name" => "Local Mac"},
           "cards" => []
         }}
      )

    assert assigns(view).notice == nil
  end

  test "paired dashboard does not crash when native push APIs are unavailable on host" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view = mount_screen(SessionDashboardScreen)

    assert assigns(view).push_status == :native_unavailable
    assert assigns(view).push_error_reason == :native_missing
    assert assigns(view).push_token == nil
    assert text(view) =~ "Push notifications unavailable"
    assert text(view) =~ "Native push token support is unavailable"
  end

  test "dashboard requests notification permission when pairing appears after mount" do
    view = mount_screen(SessionDashboardScreen)

    assert assigns(view).paired? == false
    assert assigns(view).push_status == :not_requested

    SessionConfig.put_pairing("https://casein.test", "token")

    view = render_info(view, {:mobile_cards_status, :joined})

    assert assigns(view).paired? == true
    assert assigns(view).host_url == "https://casein.test"
    assert assigns(view).push_status == :native_unavailable
    assert assigns(view).push_error_reason == :native_missing
    assert text(view) =~ "Push notifications unavailable"
  end

  test "push token request surfaces missing Firebase config" do
    previous_configured = System.get_env("MOB_FIREBASE_CONFIGURED")
    previous_reason = System.get_env("MOB_FIREBASE_CONFIG_REASON")

    System.put_env("MOB_FIREBASE_CONFIGURED", "false")
    System.put_env("MOB_FIREBASE_CONFIG_REASON", "firebase_unconfigured")

    on_exit(fn ->
      restore_env("MOB_FIREBASE_CONFIGURED", previous_configured)
      restore_env("MOB_FIREBASE_CONFIG_REASON", previous_reason)
    end)

    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:permission, :notifications, :granted})

    assert assigns(view).push_status == :native_unavailable
    assert assigns(view).push_error_reason == "firebase_unconfigured"
    assert assigns(view).push_token == nil
    assert text(view) =~ "Push notifications unavailable"
    assert text(view) =~ "Add google-services.json or Firebase build properties"
  end

  test "notification permission denial shows settings and retry actions" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:permission, :notifications, :denied})

    assert assigns(view).push_status == :permission_denied
    assert assigns(view).push_error_reason == :permission_denied
    assert text(view) =~ "Push notifications off"
    assert text(view) =~ "Enable notification permission in system settings"
    assert find(view, :button, text: "Open Settings")
    assert find(view, :button, text: "Retry")
  end

  test "notification settings action gives manual fallback when native hook is unavailable" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:permission, :notifications, :denied})
      |> render_info({:tap, :open_notification_settings})

    assert assigns(view).push_status == :permission_denied
    assert assigns(view).notice == "Open system settings for Casein and enable notifications"
    assert text(view) =~ "Open system settings for Casein and enable notifications"
  end

  test "push token errors leave registering state with Firebase failure copy" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:push_token_error, :android, "IOException"})

    assert assigns(view).push_status == :native_unavailable
    assert assigns(view).push_error_reason == {:android, "IOException"}
    assert text(view) =~ "Push notifications unavailable"
    assert text(view) =~ "Firebase push token request failed: IOException"
  end

  test "iOS push token errors surface APNs failure copy" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:push_token_error, :ios, "no valid aps-environment entitlement"})

    assert assigns(view).push_status == :native_unavailable
    assert assigns(view).push_error_reason == {:ios, "no valid aps-environment entitlement"}
    assert text(view) =~ "Push notifications unavailable"

    assert text(view) =~
             "APNs push token request failed: no valid aps-environment entitlement"
  end

  test "push token timeout leaves registering state with Firebase timeout copy" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view = mount_screen(SessionDashboardScreen)

    view = %{
      view
      | socket:
          view.socket
          |> Mob.Socket.assign(:push_status, :registering)
          |> Mob.Socket.assign(:push_token, nil)
          |> Mob.Socket.assign(:push_request_platform, :android)
    }

    view = render_info(view, :push_token_timeout)

    assert assigns(view).push_status == :native_unavailable
    assert assigns(view).push_error_reason == {:android, :firebase_token_timeout}
    assert text(view) =~ "Push notifications unavailable"
    assert text(view) =~ "Firebase did not return a push token in time"
  end

  test "iOS push token timeout leaves registering state with APNs timeout copy" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view = mount_screen(SessionDashboardScreen)

    view = %{
      view
      | socket:
          view.socket
          |> Mob.Socket.assign(:push_status, :registering)
          |> Mob.Socket.assign(:push_token, nil)
          |> Mob.Socket.assign(:push_request_platform, :ios)
    }

    view = render_info(view, :push_token_timeout)

    assert assigns(view).push_status == :native_unavailable
    assert assigns(view).push_error_reason == {:ios, :apns_token_timeout}
    assert text(view) =~ "Push notifications unavailable"
    assert text(view) =~ "APNs did not return a push token in time"
    assert text(view) =~ "aps-environment entitlement"
  end

  test "mobile card stream status is visible while disconnected" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:mobile_cards_status, :joined})
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "cards" => [
             %{
               "id" => "needs_review:ws-1:run-1",
               "type" => "needs_review",
               "workspace_id" => "ws-1",
               "title" => "Needs review offline"
             }
           ]
         }}
      )
      |> render_info({:mobile_cards_status, {:disconnected, :network_unavailable}})

    assert_renderable(view)
    assert assigns(view).mobile_cards_status == {:disconnected, :network_unavailable}
    assert text(view) =~ "casein.test · Offline"
    assert text(view) =~ "Saved profile · live feed offline"
    refute text(view) =~ "casein.test · Connected"
    refute text(view) =~ "Connected · casein.test"
    assert text(view) =~ "Card stream offline"
    assert text(view) =~ "Network unavailable"
    assert text(view) =~ "latest mobile cards may be stale"
    assert text(view) =~ "Workspace ws-1 · Last known · Offline · Read-only"
    assert find(view, :button, text: "Review").props.disabled == true
  end

  test "saved origin is called live only after authoritative card-stream authentication" do
    SessionConfig.put_pairing("https://casein.test", "token")

    connecting = mount_screen(SessionDashboardScreen)
    assert text(connecting) =~ "casein.test · Connecting"
    assert find(connecting, :button, text: "Selected · casein.test")
    refute text(connecting) =~ "Connected · casein.test"

    joined = render_info(connecting, {:mobile_cards_status, :joined})
    assert text(joined) =~ "casein.test · Live"
    assert text(joined) =~ "Authenticated live feed"

    rejected = render_info(joined, {:mobile_cards_status, {:error, :unauthorized}})
    assert text(rejected) =~ "casein.test · Pair again"
    assert text(rejected) =~ "Saved profile · authentication failed"
    refute text(rejected) =~ "· Connected"
  end

  test "mobile cards snapshot renders observer cards above workspace cards" do
    SessionConfig.put_pairing("https://casein.test", "token")
    SessionConfig.pin_workspace("ws-1")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "cards" => [
             %{
               "id" => "needs_review:ws-1:run-1",
               "type" => "needs_review",
               "priority" => "high",
               "workspace_id" => "ws-1",
               "session_id" => "run-1",
               "title" => "1 item needs review",
               "body" => "Review required before work continues",
               "action" => %{
                 "label" => "Open",
                 "route" => %{
                   "type" => "session_detail",
                   "workspace_id" => "ws-1",
                   "session_id" => "run-1"
                 }
               }
             }
           ]
         }}
      )

    assert assigns(view).mobile_cards_by_id["needs_review:ws-1:run-1"]["workspace_id"] == "ws-1"
    assert text(view) =~ "1 item needs review"
    assert text(view) =~ "needs review"
    assert text(view) =~ "Workspace ws-1"
    assert find(view, :button, text: "Review")

    view = render_info(view, {:tap, {:mobile_card_action, "needs_review:ws-1:run-1"}})
    assert navigated_to(view) == CaseinMob.ReviewDecisionScreen

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:mobile_cards_snapshot, %{"cards" => []}})

    assert assigns(view).mobile_cards_by_id == %{}
    refute text(view) =~ "1 item needs review"
  end

  test "segmented filters switch which cards are shown" do
    SessionConfig.put_pairing("https://casein.test", "token")
    SessionConfig.pin_workspace("ws-1")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "cards" => [
             %{
               "id" => "needs_review:ws-1:run-1",
               "type" => "needs_review",
               "kind" => "approval_required",
               "priority" => "high",
               "workspace_id" => "ws-1",
               "title" => "Needs review now"
             },
             %{
               "id" => "in_progress:ws-1:run-2",
               "type" => "in_progress",
               "kind" => "in_progress",
               "priority" => "normal",
               "workspace_id" => "ws-1",
               "title" => "Running mix test"
             }
           ]
         }}
      )

    assert find(view, :button, text: "Needs Me")
    assert find(view, :button, text: "Live")

    # Default segment surfaces the actionable card and hides the running one.
    assert text(view) =~ "Needs review now"
    refute text(view) =~ "Running mix test"

    view = render_info(view, {:tap, {:filter, :running}})
    assert text(view) =~ "Running mix test"
    refute text(view) =~ "Needs review now"
  end

  test "a card action result surfaces a notice" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info(
        {:card_action_result, "needs_review:ws-1:run-1", {:ok, %{"status" => "accepted"}}}
      )

    assert text(view) =~ "Action accepted"

    view = render_info(view, {:card_action_result, "c1", {:error, "note_required"}})
    assert text(view) =~ "Action failed: note required"
  end

  test "workspace idle Resume follows the channel reply contract and opens only exact echoed identity" do
    origin_id = "origin-devbox"
    put_origin_pairing(origin_id)
    start_session_client_probe()
    card = workspace_idle_card(origin_id)

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:mobile_cards_status, :joined})
      |> render_info({:mobile_cards_snapshot, mobile_cards_snapshot(origin_id, [card])})
      |> render_info({:tap, {:mobile_card_action, card["id"]}})

    assert assigns(view).pending_resume_action == %{
             action_id: "resume",
             card_id: card["id"],
             origin_id: origin_id,
             session_id: "run-9",
             source: :mobile_resume,
             workspace_id: "ws-1"
           }

    refute navigated_to(view) == CaseinMob.SessionDetailScreen

    assert_receive {:session_client_cast,
                    {:card_action, "workspace_idle:ws-1:run-9", "resume", %{}, ^origin_id}}

    view =
      render_info(
        view,
        {:card_action_result, card["id"],
         {:ok,
          %{
            "status" => "accepted",
            "card_id" => card["id"],
            "action_id" => "resume",
            "idempotent" => false,
            "result" => %{
              "target" => "session_detail",
              "workspace_id" => "ws-1",
              "session_id" => "run-9"
            }
          }}}
      )

    assert assigns(view).pending_resume_action == nil
    assert navigated_to(view) == CaseinMob.SessionDetailScreen

    assert SessionConfig.resume_context() == %{
             workspace_id: "ws-1",
             session_id: "run-9",
             source: :mobile_resume
           }
  end

  test "workspace idle Resume waits for an authoritative active-origin snapshot" do
    origin_id = "origin-devbox"
    put_origin_pairing(origin_id)
    start_session_client_probe()
    card = workspace_idle_card(origin_id)

    snapshots = [
      mobile_cards_snapshot(origin_id, [card]) |> Map.delete("live_work"),
      mobile_cards_snapshot(origin_id, [card], "hydrating")
    ]

    Enum.each(snapshots, fn snapshot ->
      view =
        SessionDashboardScreen
        |> mount_screen()
        |> render_info({:mobile_cards_status, :joined})
        |> render_info({:mobile_cards_snapshot, snapshot})
        |> render_info({:tap, {:mobile_card_action, card["id"]}})

      assert assigns(view).pending_resume_action == nil
      refute navigated_to(view) == CaseinMob.SessionDetailScreen
      assert SessionConfig.resume_context() == nil
      assert text(view) =~ "Wait for authoritative refresh before resuming"
    end)

    refute_receive {:session_client_cast, {:card_action, _, "resume", _, _}}
  end

  test "workspace idle Resume coalesces duplicate taps and ignores unrelated action replies" do
    origin_id = "origin-devbox"
    put_origin_pairing(origin_id)
    start_session_client_probe()
    card = workspace_idle_card(origin_id)

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:mobile_cards_status, :joined})
      |> render_info({:mobile_cards_snapshot, mobile_cards_snapshot(origin_id, [card])})
      |> render_info({:tap, {:mobile_card_action, card["id"]}})

    assert_receive {:session_client_cast,
                    {:card_action, "workspace_idle:ws-1:run-9", "resume", %{}, ^origin_id}}

    view = render_info(view, {:tap, {:mobile_card_action, card["id"]}})

    assert text(view) =~ "Resume is already in progress"

    refute_receive {:session_client_cast,
                    {:card_action, "workspace_idle:ws-1:run-9", "resume", %{}, ^origin_id}}

    view =
      render_info(
        view,
        {:card_action_result, "workspace_idle:ws-other:run-other",
         {:ok, %{"status" => "accepted"}}}
      )

    assert assigns(view).pending_resume_action.card_id == card["id"]
    refute navigated_to(view) == CaseinMob.SessionDetailScreen
    assert text(view) =~ "Resume is already in progress"

    view =
      render_info(
        view,
        {:card_action_result, card["id"],
         {:ok,
          %{
            "status" => "accepted",
            "card_id" => card["id"],
            "action_id" => "resume",
            "idempotent" => true,
            "result" => %{
              "target" => "session_detail",
              "workspace_id" => "ws-1",
              "session_id" => "run-9"
            }
          }}}
      )

    assert navigated_to(view) == CaseinMob.SessionDetailScreen

    assert SessionConfig.resume_context() == %{
             workspace_id: "ws-1",
             session_id: "run-9",
             source: :mobile_resume
           }
  end

  test "workspace idle Resume rejects missing or mismatched reply identity" do
    origin_id = "origin-devbox"
    put_origin_pairing(origin_id)
    start_session_client_probe()
    card = workspace_idle_card(origin_id)

    accepted = %{
      "status" => "accepted",
      "card_id" => card["id"],
      "action_id" => "resume",
      "result" => %{
        "target" => "session_detail",
        "workspace_id" => "ws-1",
        "session_id" => "run-9"
      }
    }

    replies = [
      Map.delete(accepted, "card_id"),
      Map.delete(accepted, "action_id"),
      Map.put(accepted, "card_id", "workspace_idle:ws-other:run-9"),
      Map.put(accepted, "action_id", "other")
    ]

    Enum.each(replies, fn reply ->
      view =
        SessionDashboardScreen
        |> mount_screen()
        |> render_info({:mobile_cards_status, :joined})
        |> render_info({:mobile_cards_snapshot, mobile_cards_snapshot(origin_id, [card])})
        |> render_info({:tap, {:mobile_card_action, card["id"]}})

      assert_receive {:session_client_cast,
                      {:card_action, "workspace_idle:ws-1:run-9", "resume", %{}, ^origin_id}}

      view = render_info(view, {:card_action_result, card["id"], {:ok, reply}})

      assert assigns(view).pending_resume_action == nil
      refute navigated_to(view) == CaseinMob.SessionDetailScreen
      assert SessionConfig.resume_context() == nil
      assert text(view) =~ "Resume target changed; nothing was opened"
    end)
  end

  test "workspace idle Resume rejects malformed or internally mismatched session targets" do
    origin_id = "origin-devbox"
    put_origin_pairing(origin_id)
    start_session_client_probe()
    valid = workspace_idle_card(origin_id)

    malformed_cards = [
      Map.delete(valid, "session_id"),
      put_in(valid, ["actions", Access.at(0), "route", "session_id"], "run-other"),
      put_in(valid, ["actions", Access.at(0), "route", "workspace_id"], "ws-other"),
      put_in(valid, ["resume", "locator", "session_id"], "run-other"),
      put_in(valid, ["resume", "card_id"], "workspace_idle:ws-1:run-other"),
      update_in(valid, ["actions", Access.at(0), "route"], &Map.delete(&1, "session_id"))
    ]

    Enum.each(malformed_cards, fn card ->
      view =
        SessionDashboardScreen
        |> mount_screen()
        |> render_info({:mobile_cards_status, :joined})
        |> render_info({:mobile_cards_snapshot, mobile_cards_snapshot(origin_id, [card])})
        |> render_info({:tap, {:mobile_card_action, card["id"]}})

      assert assigns(view).pending_resume_action == nil
      refute navigated_to(view) == CaseinMob.SessionDetailScreen
      assert SessionConfig.resume_context() == nil
    end)

    refute_receive {:session_client_cast, {:card_action, _, "resume", _, _}}
  end

  test "workspace idle Resume rejects an inactive origin and an offline tap" do
    put_origin_pairing("origin-devbox")
    start_session_client_probe()

    inactive_card = workspace_idle_card("origin-other")

    inactive_view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:mobile_cards_status, :joined})
      |> render_info(
        {:mobile_cards_snapshot, mobile_cards_snapshot("origin-devbox", [inactive_card])}
      )
      |> render_info({:tap, {:mobile_card_action, inactive_card["id"]}})

    assert assigns(inactive_view).pending_resume_action == nil
    refute navigated_to(inactive_view) == CaseinMob.SessionDetailScreen

    active_card = workspace_idle_card("origin-devbox")

    offline_view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:mobile_cards_status, :joined})
      |> render_info(
        {:mobile_cards_snapshot, mobile_cards_snapshot("origin-devbox", [active_card])}
      )
      |> render_info({:mobile_cards_status, {:disconnected, :network_unavailable}})
      |> render_info({:tap, {:mobile_card_action, active_card["id"]}})

    assert assigns(offline_view).pending_resume_action == nil
    refute navigated_to(offline_view) == CaseinMob.SessionDetailScreen
    assert text(offline_view) =~ "Reconnect and refresh before resuming"
    refute_receive {:session_client_cast, {:card_action, _, "resume", _, _}}
  end

  test "workspace idle Resume rejects a stale or mismatched accepted reply" do
    origin_id = "origin-devbox"
    put_origin_pairing(origin_id)
    start_session_client_probe()
    card = workspace_idle_card(origin_id)

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:mobile_cards_status, :joined})
      |> render_info({:mobile_cards_snapshot, mobile_cards_snapshot(origin_id, [card])})
      |> render_info({:tap, {:mobile_card_action, card["id"]}})
      |> render_info(
        {:card_action_result, card["id"],
         {:ok,
          %{
            "status" => "accepted",
            "card_id" => card["id"],
            "action_id" => "resume",
            "result" => %{
              "target" => "session_detail",
              "workspace_id" => "ws-1",
              "session_id" => "run-other"
            }
          }}}
      )

    assert assigns(view).pending_resume_action == nil
    refute navigated_to(view) == CaseinMob.SessionDetailScreen
    assert SessionConfig.resume_context() == nil
    assert text(view) =~ "Resume target changed; nothing was opened"

    stale_view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:mobile_cards_status, :joined})
      |> render_info({:mobile_cards_snapshot, mobile_cards_snapshot(origin_id, [card])})
      |> render_info({:tap, {:mobile_card_action, card["id"]}})
      |> render_info({:mobile_cards_snapshot, mobile_cards_snapshot(origin_id, [])})
      |> render_info(
        {:card_action_result, card["id"],
         {:ok,
          %{
            "status" => "accepted",
            "card_id" => card["id"],
            "action_id" => "resume",
            "result" => %{
              "target" => "session_detail",
              "workspace_id" => "ws-1",
              "session_id" => "run-9"
            }
          }}}
      )

    assert assigns(stale_view).pending_resume_action == nil
    refute navigated_to(stale_view) == CaseinMob.SessionDetailScreen
    assert SessionConfig.resume_context() == nil
    assert text(stale_view) =~ "Resume request is stale; nothing was opened"
  end

  test "workspace idle Resume rejects an accepted reply after authority regresses" do
    origin_id = "origin-devbox"
    put_origin_pairing(origin_id)
    start_session_client_probe()
    card = workspace_idle_card(origin_id)

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:mobile_cards_status, :joined})
      |> render_info({:mobile_cards_snapshot, mobile_cards_snapshot(origin_id, [card])})
      |> render_info({:tap, {:mobile_card_action, card["id"]}})

    assert_receive {:session_client_cast,
                    {:card_action, "workspace_idle:ws-1:run-9", "resume", %{}, ^origin_id}}

    view =
      render_info(
        view,
        {:mobile_cards_snapshot, mobile_cards_snapshot(origin_id, [card], "hydrating")}
      )

    assert assigns(view).pending_resume_action.card_id == card["id"]

    view =
      render_info(
        view,
        {:card_action_result, card["id"],
         {:ok,
          %{
            "status" => "accepted",
            "card_id" => card["id"],
            "action_id" => "resume",
            "result" => %{
              "target" => "session_detail",
              "workspace_id" => "ws-1",
              "session_id" => "run-9"
            }
          }}}
      )

    assert assigns(view).pending_resume_action == nil
    refute navigated_to(view) == CaseinMob.SessionDetailScreen
    assert SessionConfig.resume_context() == nil
    assert text(view) =~ "Resume cancelled; refresh is not authoritative"
  end

  test "workspace idle Resume rejects an accepted reply after card replacement" do
    origin_id = "origin-devbox"
    put_origin_pairing(origin_id)
    start_session_client_probe()
    card = workspace_idle_card(origin_id)

    replacement =
      card
      |> Map.put("session_id", "run-10")
      |> put_in(["resume", "locator", "session_id"], "run-10")
      |> put_in(["actions", Access.at(0), "route", "session_id"], "run-10")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:mobile_cards_status, :joined})
      |> render_info({:mobile_cards_snapshot, mobile_cards_snapshot(origin_id, [card])})
      |> render_info({:tap, {:mobile_card_action, card["id"]}})

    assert_receive {:session_client_cast,
                    {:card_action, "workspace_idle:ws-1:run-9", "resume", %{}, ^origin_id}}

    view =
      view
      |> render_info({:mobile_cards_snapshot, mobile_cards_snapshot(origin_id, [replacement])})
      |> render_info(
        {:card_action_result, card["id"],
         {:ok,
          %{
            "status" => "accepted",
            "card_id" => card["id"],
            "action_id" => "resume",
            "result" => %{
              "target" => "session_detail",
              "workspace_id" => "ws-1",
              "session_id" => "run-9"
            }
          }}}
      )

    assert assigns(view).pending_resume_action == nil
    refute navigated_to(view) == CaseinMob.SessionDetailScreen
    assert SessionConfig.resume_context() == nil
    assert text(view) =~ "Resume target changed; nothing was opened"
  end

  test "workspace idle Resume cancels a pending open on disconnect" do
    origin_id = "origin-devbox"
    put_origin_pairing(origin_id)
    start_session_client_probe()
    card = workspace_idle_card(origin_id)

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:mobile_cards_status, :joined})
      |> render_info({:mobile_cards_snapshot, mobile_cards_snapshot(origin_id, [card])})
      |> render_info({:tap, {:mobile_card_action, card["id"]}})
      |> render_info({:mobile_cards_status, {:disconnected, :network_unavailable}})

    assert assigns(view).pending_resume_action == nil
    refute navigated_to(view) == CaseinMob.SessionDetailScreen
    assert text(view) =~ "Resume cancelled; reconnect and refresh"

    view =
      render_info(
        view,
        {:card_action_result, card["id"],
         {:ok,
          %{
            "status" => "accepted",
            "card_id" => card["id"],
            "action_id" => "resume",
            "result" => %{
              "target" => "session_detail",
              "workspace_id" => "ws-1",
              "session_id" => "run-9"
            }
          }}}
      )

    refute navigated_to(view) == CaseinMob.SessionDetailScreen
    assert SessionConfig.resume_context() == nil
  end

  test "card navigation prefers the normalized action route over the legacy route" do
    SessionConfig.put_pairing("https://casein.test", "token")

    # Normalized route points at the session detail; the legacy route disagrees
    # (retry). Preferring the normalized route means we navigate to the detail.
    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "cards" => [
             %{
               "id" => "in_progress:ws-1:run-1",
               "type" => "in_progress",
               "kind" => "in_progress",
               "workspace_id" => "ws-1",
               "title" => "Running",
               "actions" => [
                 %{
                   "id" => "open",
                   "route" => %{
                     "type" => "session_detail",
                     "workspace_id" => "ws-1",
                     "session_id" => "run-1"
                   }
                 }
               ],
               "action" => %{
                 "label" => "Retry",
                 "route" => %{"type" => "retry_workspace", "workspace_id" => "ws-1"}
               }
             }
           ]
         }}
      )

    view = render_info(view, {:tap, {:mobile_card_action, "in_progress:ws-1:run-1"}})
    assert navigated_to(view) == CaseinMob.SessionDetailScreen
    assert SessionConfig.resume_context() == %{workspace_id: "ws-1", source: :workspace}
  end

  test "an empty segment shows an actionable empty state" do
    SessionConfig.put_pairing("https://casein.test", "token")
    SessionConfig.pin_workspace("ws-1")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:mobile_cards_snapshot, %{"cards" => []}})

    assert text(view) =~ "Nothing needs you"
  end

  test "hydrating live work never presents an authoritative empty state" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info(
        {:mobile_cards_snapshot, %{"cards" => [], "live_work" => %{"status" => "hydrating"}}}
      )

    assert text(view) =~ "Syncing live work"
    refute text(view) =~ "Nothing needs you"
  end

  test "attention projection explains priority, required decision, and changes since viewed" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "cards" => [
             %{
               "id" => "needs_review:ws-1:run-1",
               "type" => "needs_review",
               "priority" => "high",
               "workspace_id" => "ws-1",
               "title" => "Agent needs review",
               "attention" => %{
                 "identity" => "origin-local:ws-1:session:run-1",
                 "key" => "ws-1:session:run-1",
                 "priority" => "critical",
                 "rank" => 680,
                 "explanation" => "A review decision is waiting",
                 "required_decision" => "Review",
                 "since_viewed" => %{
                   "count" => 2,
                   "through_marker" => 42,
                   "changes" => [%{"label" => "Decision requested"}]
                 }
               }
             }
           ]
         }}
      )

    assert text(view) =~ "Why now: A review decision is waiting"
    assert text(view) =~ "2 changes since you looked · Decision requested"
    assert text(view) =~ "Review"
  end

  test "Needs Me includes failed and completed cards with a declared decision" do
    SessionConfig.put_pairing("https://casein.test", "token")

    cards =
      for {id, state, title, decision} <- [
            {"failed", "failed", "Failed work needs inspection", "Inspect failure"},
            {"completed", "completed", "Completed work needs review", "Review outcome"}
          ] do
        %{
          "id" => id,
          "type" => "outcome",
          "kind" => "run_" <> state,
          "status" => state,
          "workspace_id" => "ws-1",
          "title" => title,
          "resume" => %{"state" => state},
          "attention" => %{
            "identity" => "origin-local:#{id}",
            "priority" => "high",
            "rank" => 500,
            "required_decision" => decision
          }
        }
      end

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:mobile_cards_snapshot, %{"cards" => cards}})

    rendered = text(view)
    assert rendered =~ "Failed work needs inspection"
    assert rendered =~ "Completed work needs review"
    refute rendered =~ "Nothing needs you"
  end

  test "same-priority cards order by newest meaningful change before identity" do
    SessionConfig.put_pairing("https://casein.test", "token")

    card = fn id, title, occurred_at ->
      %{
        "id" => id,
        "type" => "needs_review",
        "workspace_id" => "ws-1",
        "title" => title,
        "attention" => %{
          "identity" => "origin-local:#{id}",
          "priority" => "critical",
          "rank" => 680,
          "required_decision" => "Review",
          "since_viewed" => %{
            "count" => 1,
            "changes" => [%{"label" => "Decision requested", "occurred_at" => occurred_at}]
          }
        }
      }
    end

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "cards" => [
             card.("a", "Older decision", "2026-07-28T08:00:00Z"),
             card.("z", "Newer decision", "2026-07-28T09:00:00Z")
           ]
         }}
      )

    rendered = text(view)
    {newer_offset, _} = :binary.match(rendered, "Newer decision")
    {older_offset, _} = :binary.match(rendered, "Older decision")
    assert newer_offset < older_offset
  end

  test "unresolved Needs Me stays pinned above Live after viewing in an inactive-origin cache" do
    SessionConfig.put_pairing(%{
      origin_id: "origin-b",
      display_name: "Other origin",
      url: "https://other.test",
      token: "other-token"
    })

    unresolved = %{
      "id" => "cached-direction",
      "qualified_id" => "origin-b:cached-direction",
      "type" => "clarification",
      "kind" => "direction_required",
      "status" => "waiting",
      "priority" => "low",
      "workspace_id" => "ws-cached",
      "title" => "Cached unresolved direction",
      "origin" => %{"id" => "origin-b", "display_name" => "Other origin"},
      "attention" => %{
        "identity" => "origin-b:ws-cached:session:run-1",
        "priority" => "low",
        "rank" => 1,
        "required_decision" => "Choose",
        "unresolved?" => true,
        "pin" => "needs_me",
        "since_viewed" => %{"count" => 0, "viewed_through_marker" => 42}
      }
    }

    assert :ok =
             SessionConfig.cache_cards("origin-b", [unresolved], "2026-07-28T08:00:00Z")

    SessionConfig.put_pairing(%{
      origin_id: "origin-a",
      display_name: "Active origin",
      url: "https://active.test",
      token: "active-token"
    })

    live = %{
      "id" => "live-run",
      "type" => "in_progress",
      "kind" => "in_progress",
      "status" => "running",
      "priority" => "normal",
      "workspace_id" => "ws-live",
      "title" => "Live work",
      "resume" => %{"state" => "working"},
      "attention" => %{
        "identity" => "origin-a:ws-live:session:run-2",
        "priority" => "low",
        "rank" => 120,
        "since_viewed" => %{"count" => 0}
      }
    }

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:mobile_cards_snapshot, %{"cards" => [live]}})

    rendered = text(view)
    assert rendered =~ "Cached unresolved direction"
    refute rendered =~ "Live work"
    assert rendered =~ "Cached"
    assert rendered =~ "Read-only"

    view = render_info(view, {:tap, {:filter, :running}})
    assert text(view) =~ "Live work"
    refute text(view) =~ "Cached unresolved direction"
  end

  test "sticky direction card and open control expose bounded XCUITest identifiers" do
    SessionConfig.put_pairing("https://casein.test", "token")

    sticky = %{
      "id" => "direction:ws-1:run-1",
      "type" => "clarification",
      "kind" => "direction_required",
      "sticky" => true,
      "status" => "waiting",
      "workspace_id" => "ws-1",
      "title" => "Choose the next direction",
      "attention" => %{"unresolved?" => true, "pin" => "needs_me"}
    }

    non_sticky = %{
      "id" => "approval:ws-1:run-2",
      "type" => "needs_review",
      "kind" => "approval_required",
      "status" => "waiting",
      "workspace_id" => "ws-1",
      "title" => "Review another request"
    }

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:mobile_cards_status, :joined})
      |> render_info({:mobile_cards_snapshot, %{"cards" => [non_sticky, sticky]}})

    columns = find_all(view, :column)

    assert Enum.any?(columns, &(&1.props[:test_id] == "needs-me-card-sticky-direction"))
    assert Enum.any?(columns, &(&1.props[:test_id] == "needs-me-card-non-sticky"))

    buttons = find_all(view, :button)

    assert Enum.any?(buttons, &(&1.props[:test_id] == "needs-me-open-sticky-direction"))
    assert Enum.any?(buttons, &(&1.props[:test_id] == "needs-me-open-non-sticky"))

    rendered = text(view)
    {sticky_offset, _} = :binary.match(rendered, sticky["title"])
    {non_sticky_offset, _} = :binary.match(rendered, non_sticky["title"])
    assert sticky_offset < non_sticky_offset
  end

  test "authoritatively handled decision is released from Needs Me" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "cards" => [
             %{
               "id" => "handled-direction",
               "type" => "clarification",
               "kind" => "direction_required",
               "status" => "handled",
               "workspace_id" => "ws-1",
               "title" => "Handled direction",
               "attention" => %{
                 "required_decision" => "Choose",
                 "unresolved?" => false,
                 "pin" => nil
               },
               "resume" => %{"state" => "completed"}
             }
           ]
         }}
      )

    assert text(view) =~ "Nothing needs you"
    refute text(view) =~ "Handled direction"

    view = render_info(view, {:tap, {:filter, :done}})
    assert text(view) =~ "Handled direction"
  end

  test "mobile cards can render without pinned workspaces" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "cards" => [
             %{
               "id" => "needs_review:ws-1:run-1",
               "type" => "needs_review",
               "priority" => "high",
               "workspace_id" => "ws-1",
               "title" => "2 items need review",
               "body" => "Review required before work continues",
               "action" => %{
                 "label" => "Open",
                 "route" => %{"type" => "session_detail", "workspace_id" => "ws-1"}
               }
             }
           ]
         }}
      )

    assert text(view) =~ "2 items need review"
    refute text(view) =~ "No workspace pinned"
  end

  test "needs review observer cards route decisions through review screen" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "cards" => [
             %{
               "id" => "needs_review:ws-1:run-1",
               "type" => "needs_review",
               "priority" => "high",
               "workspace_id" => "ws-1",
               "title" => "1 item needs review",
               "body" => "Review required before work continues",
               "action" => %{
                 "label" => "Open",
                 "route" => %{"type" => "session_detail", "workspace_id" => "ws-1"}
               }
             }
           ]
         }}
      )

    assert find(view, :button, text: "Review")
    refute find(view, :button, text: "Approve")
    refute find(view, :button, text: "Deny")

    view = render_info(view, {:tap, {:mobile_card_action, "needs_review:ws-1:run-1"}})

    assert navigated_to(view) == CaseinMob.ReviewDecisionScreen
  end

  test "mobile connection issue card retry uses workspace reconnect path" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "cards" => [
             %{
               "id" => "connection_issue:ws-1:nil",
               "type" => "connection_issue",
               "priority" => "normal",
               "workspace_id" => "ws-1",
               "title" => "Workspace offline",
               "body" => "Last seen 8m ago",
               "action" => %{
                 "label" => "Retry",
                 "route" => %{"type" => "retry_workspace", "workspace_id" => "ws-1"}
               }
             }
           ]
         }}
      )
      |> render_info({:tap, {:mobile_card_action, "connection_issue:ws-1:nil"}})

    assert assigns(view).statuses["ws-1"] == :connecting
    assert text(view) =~ "Reconnecting ws-1..."
  end

  test "push tokens register for joined pinned and observer-card workspaces" do
    SessionConfig.put_pairing("https://casein.test", "token")
    SessionConfig.pin_workspace("ws-1")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:session_status, "ws-1", :joined})
      |> render_info({:push_token, :ios, "apns-token"})

    assert assigns(view).push_status == :registering
    assert assigns(view).push_token == %{platform: "ios", token: "apns-token"}
    refute MapSet.member?(assigns(view).push_registered_workspace_ids, "ws-1")

    view = render_info(view, {:push_registration_status, "ws-1", :registered})

    assert assigns(view).push_status == :registered
    assert MapSet.member?(assigns(view).push_registered_workspace_ids, "ws-1")

    view =
      view
      |> render_info({:mobile_cards_status, :joined})
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "cards" => [
             %{
               "id" => "needs_review:ws-2:run-1",
               "type" => "needs_review",
               "priority" => "high",
               "workspace_id" => "ws-2",
               "title" => "1 item needs review"
             }
           ]
         }}
      )

    assert assigns(view).push_status == :registering
    refute MapSet.member?(assigns(view).push_registered_workspace_ids, "ws-2")

    view = render_info(view, {:push_registration_status, "ws-2", :registered})

    assert assigns(view).push_status == :registered
    assert MapSet.member?(assigns(view).push_registered_workspace_ids, "ws-2")
  end

  test "push token waits for a joined stream before backend registration" do
    SessionConfig.put_pairing("https://casein.test", "token")
    SessionConfig.pin_workspace("ws-1")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:push_token, :android, "fcm-token"})

    assert assigns(view).push_status == :registration_pending
    assert assigns(view).push_token == %{platform: "android", token: "fcm-token"}
    assert assigns(view).push_registered_workspace_ids == MapSet.new()

    view = render_info(view, {:session_status, "ws-1", :joined})

    assert assigns(view).push_status == :registering
    assert assigns(view).push_registered_workspace_ids == MapSet.new()

    view = render_info(view, {:push_registration_status, "ws-1", {:error, :unauthorized}})

    assert assigns(view).push_status == :registration_failed
    assert assigns(view).push_registered_workspace_ids == MapSet.new()
  end

  test "push token registers against the user card stream once joined" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:push_token, :android, "fcm-token"})

    assert assigns(view).push_status == :registration_pending
    assert assigns(view).push_user_registered? == false
    assert assigns(view).push_user_registration_pending? == false
    assert assigns(view).push_registered_workspace_ids == MapSet.new()
    assert text(view) =~ "Push registration_pending · token yes · user no · workspaces 0"

    view = render_info(view, {:mobile_cards_status, :joined})

    assert assigns(view).push_status == :registering
    assert assigns(view).push_user_registration_pending? == true
    assert assigns(view).push_registered_workspace_ids == MapSet.new()
    assert text(view) =~ "Push registering · token yes · user no · workspaces 0"

    view = render_info(view, {:push_registration_status, :user, :registered})

    assert assigns(view).push_status == :registered
    assert assigns(view).push_user_registered? == true
    assert assigns(view).push_user_registration_pending? == false
    assert assigns(view).push_registered_workspace_ids == MapSet.new()
    assert text(view) =~ "Push registered · token yes · user yes · workspaces 0"
  end

  test "push registration surfaces backend provider setup failure" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:push_token, :android, "fcm-token"})
      |> render_info({:mobile_cards_status, :joined})

    assert assigns(view).push_status == :registering
    assert assigns(view).push_user_registration_pending? == true

    view =
      render_info(
        view,
        {:push_registration_status, :user, {:error, "push_provider_unconfigured"}}
      )

    assert assigns(view).push_status == :registration_failed
    assert assigns(view).push_user_registration_pending? == false
    assert text(view) =~ "Server push delivery is not configured yet"
  end

  test "needs review push notification opens a loaded review card" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "cards" => [
             %{
               "id" => "needs_review:ws-1:run-1",
               "type" => "needs_review",
               "priority" => "high",
               "workspace_id" => "ws-1",
               "title" => "1 item needs review"
             }
           ]
         }}
      )
      |> render_info(
        {:notification,
         %{
           source: :push,
           data: %{
             action: "mobile.needs_review",
             card_id: "needs_review:ws-1:run-1",
             card_type: "needs_review"
           }
         }}
      )

    assert navigated_to(view) == CaseinMob.ReviewDecisionScreen
  end

  test "live intervention card opens the bounded response surface" do
    SessionConfig.put_pairing(%{
      origin_id: "origin-local",
      display_name: "Local Mac",
      url: "https://casein.test",
      token: "token"
    })

    card = %{
      "id" => "in_progress:ws-1:run-1",
      "type" => "in_progress",
      "workspace_id" => "ws-1",
      "title" => "Agent needs direction",
      "intervention" => %{
        "recent_output" => "Need a decision",
        "pwa_url" => "https://casein.test/workspaces/ws-1"
      },
      "actions" => [%{"id" => "follow_up", "label" => "Send follow-up"}]
    }

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:mobile_cards_status, :joined})
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "origin" => %{"id" => "origin-local", "display_name" => "Local Mac"},
           "cards" => [card]
         }}
      )
      |> render_info({:tap, {:filter, :running}})

    primary_action = find(view, :button, text: "Open")
    assert primary_action.props.fill_width == true
    refute Map.has_key?(primary_action.props, :weight)
    assert primary_action.props.disabled == false

    view = render_info(view, {:tap, {:mobile_card_action, card["id"]}})
    assert navigated_to(view) == CaseinMob.ReviewDecisionScreen
  end

  test "needs review push notification waits for the next matching snapshot" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info(
        {:notification,
         %{
           source: :push,
           data: %{
             "action" => "mobile.needs_review",
             "card_id" => "needs_review:ws-1:run-1",
             "deep_link" => "casein://review/needs_review%3Aws-1%3Arun-1"
           }
         }}
      )

    assert assigns(view).pending_notification_card_id == "needs_review:ws-1:run-1"
    assert text(view) =~ "Review card will open after cards refresh"

    view =
      render_info(
        view,
        {:mobile_cards_snapshot,
         %{
           "cards" => [
             %{
               "id" => "needs_review:ws-1:run-1",
               "type" => "needs_review",
               "priority" => "high",
               "workspace_id" => "ws-1",
               "title" => "1 item needs review"
             }
           ]
         }}
      )

    assert navigated_to(view) == CaseinMob.ReviewDecisionScreen
  end

  test "cached inactive-origin card switches, refreshes, then opens authoritative review" do
    SessionConfig.put_pairing(%{
      origin_id: "origin-mac",
      display_name: "Local Mac",
      url: "https://mac.test",
      token: "mac-token"
    })

    cached_card = %{
      "id" => "needs_review:mac-ws:run-1",
      "type" => "needs_review",
      "kind" => "approval_required",
      "priority" => "high",
      "workspace_id" => "mac-ws",
      "session_id" => "run-1",
      "title" => "Mac work needs review",
      "resume" => %{
        "state" => "needs_attention",
        "locator" => %{
          "origin_id" => "origin-mac",
          "workspace_id" => "mac-ws",
          "session_id" => "run-1"
        }
      }
    }

    assert :ok =
             SessionConfig.cache_cards("origin-mac", [cached_card], "2026-07-23T12:00:00Z")

    SessionConfig.put_pairing(%{
      origin_id: "origin-devbox",
      display_name: "Devbox",
      url: "https://devbox.test",
      token: "devbox-token"
    })

    view = mount_screen(SessionDashboardScreen)
    assert text(view) =~ "Mac work needs review"
    assert text(view) =~ "Read-only"

    qualified_id = "origin-mac:needs_review:mac-ws:run-1"
    view = render_info(view, {:tap, {:mobile_card_action, qualified_id}})

    assert {:ok, %{origin_id: "origin-mac"}} = SessionConfig.connection()
    assert assigns(view).pending_origin_resume.origin_id == "origin-mac"
    refute navigated_to(view) == CaseinMob.ReviewDecisionScreen

    view =
      render_info(
        view,
        {:mobile_cards_snapshot,
         %{
           "origin" => %{"id" => "origin-mac", "display_name" => "Local Mac"},
           "cards" => [cached_card]
         }}
      )

    assert assigns(view).pending_origin_resume == nil
    assert navigated_to(view) == CaseinMob.ReviewDecisionScreen
  end

  test "cached inactive-origin workspace idle Resume refreshes and dispatches before exact open" do
    SessionConfig.put_pairing(%{
      origin_id: "origin-mac",
      display_name: "Local Mac",
      url: "https://mac.test",
      token: "mac-token"
    })

    card = workspace_idle_card("origin-mac")
    assert :ok = SessionConfig.cache_cards("origin-mac", [card], "2026-07-23T12:00:00Z")

    SessionConfig.put_pairing(%{
      origin_id: "origin-devbox",
      display_name: "Devbox",
      url: "https://devbox.test",
      token: "devbox-token"
    })

    start_session_client_probe()

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:tap, {:mobile_card_action, "origin-mac:workspace_idle:ws-1:run-9"}})

    assert {:ok, %{origin_id: "origin-mac"}} = SessionConfig.connection()
    assert assigns(view).pending_origin_resume.origin_id == "origin-mac"
    assert assigns(view).pending_resume_action == nil
    refute navigated_to(view) == CaseinMob.SessionDetailScreen

    hydrating_view =
      render_info(
        view,
        {:mobile_cards_snapshot,
         %{
           "origin" => %{"id" => "origin-mac", "display_name" => "Local Mac"},
           "live_work" => %{"status" => "hydrating"},
           "cards" => [card]
         }}
      )

    assert assigns(hydrating_view).pending_origin_resume.origin_id == "origin-mac"
    assert assigns(hydrating_view).pending_resume_action == nil

    refute_receive {:session_client_cast,
                    {:card_action, "workspace_idle:ws-1:run-9", "resume", %{}, "origin-mac"}}

    view =
      hydrating_view
      |> render_info({:mobile_cards_status, :joined})
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "origin" => %{"id" => "origin-mac", "display_name" => "Local Mac"},
           "live_work" => %{"status" => "authoritative"},
           "cards" => [card]
         }}
      )

    assert assigns(view).pending_origin_resume == nil

    assert assigns(view).pending_resume_action == %{
             action_id: "resume",
             card_id: "workspace_idle:ws-1:run-9",
             origin_id: "origin-mac",
             session_id: "run-9",
             source: :origin_resume,
             workspace_id: "ws-1"
           }

    assert_receive {:session_client_cast,
                    {:card_action, "workspace_idle:ws-1:run-9", "resume", %{}, "origin-mac"}}

    refute navigated_to(view) == CaseinMob.SessionDetailScreen

    view =
      view
      |> render_info({:mobile_cards_status, :joined})
      |> render_info(
        {:card_action_result, card["id"],
         {:ok,
          %{
            "status" => "accepted",
            "card_id" => card["id"],
            "action_id" => "resume",
            "result" => %{
              "target" => "session_detail",
              "workspace_id" => "ws-1",
              "session_id" => "run-9"
            }
          }}}
      )

    assert navigated_to(view) == CaseinMob.SessionDetailScreen

    assert SessionConfig.resume_context() == %{
             workspace_id: "ws-1",
             session_id: "run-9",
             source: :origin_resume
           }
  end

  test "unknown push origin never switches or opens a card" do
    SessionConfig.put_pairing(%{
      origin_id: "origin-devbox",
      display_name: "Devbox",
      url: "https://devbox.test",
      token: "devbox-token"
    })

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info(
        {:notification,
         %{
           data: %{
             action: "mobile.needs_review",
             origin_id: "tampered-origin",
             card_id: "needs_review:ws-1:run-1",
             workspace_id: "ws-1"
           }
         }}
      )

    assert {:ok, %{origin_id: "origin-devbox"}} = SessionConfig.connection()
    assert assigns(view).pending_origin_resume == nil
    assert text(view) =~ "Unknown origin; nothing was opened"
    refute navigated_to(view) == CaseinMob.ReviewDecisionScreen
  end

  test "missing refreshed workspace idle card fails closed instead of opening its stale locator" do
    SessionConfig.put_pairing(%{
      origin_id: "origin-mac",
      display_name: "Local Mac",
      url: "https://mac.test",
      token: "mac-token"
    })

    cached_card = %{
      "id" => "completed:mac-ws:session-9",
      "type" => "workspace_idle",
      "kind" => "workspace_idle",
      "priority" => "low",
      "workspace_id" => "mac-ws",
      "session_id" => "session-9",
      "title" => "Resume Mac work",
      "resume" => %{
        "state" => "completed",
        "locator" => %{
          "origin_id" => "origin-mac",
          "workspace_id" => "mac-ws",
          "session_id" => "session-9",
          "tab" => "diff"
        }
      }
    }

    :ok = SessionConfig.cache_cards("origin-mac", [cached_card], "2026-07-23T12:00:00Z")

    SessionConfig.put_pairing(%{
      origin_id: "origin-devbox",
      display_name: "Devbox",
      url: "https://devbox.test",
      token: "devbox-token"
    })

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:tap, {:mobile_card_action, "origin-mac:completed:mac-ws:session-9"}})
      |> render_info({:mobile_cards_status, :joined})
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "origin" => %{"id" => "origin-mac", "display_name" => "Local Mac"},
           "live_work" => %{"status" => "authoritative"},
           "cards" => []
         }}
      )

    refute navigated_to(view) == CaseinMob.SessionDetailScreen
    assert SessionConfig.resume_context() == nil
    assert text(view) =~ "Resume is no longer available after refresh"
  end

  test "mismatched authoritative snapshot is rejected without replacing live cards" do
    SessionConfig.put_pairing(%{
      origin_id: "origin-devbox",
      display_name: "Devbox",
      url: "https://devbox.test",
      token: "devbox-token"
    })

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "origin" => %{"id" => "tampered-origin", "display_name" => "Other"},
           "cards" => [
             %{
               "id" => "needs_review:ws-1:run-1",
               "type" => "needs_review",
               "workspace_id" => "ws-1",
               "title" => "Must not render"
             }
           ]
         }}
      )

    assert assigns(view).mobile_cards == []
    assert text(view) =~ "Origin mismatch; state was not accepted"
    refute text(view) =~ "Must not render"
  end

  test "dev notification JSON can inject a pending review notification at launch" do
    System.put_env(
      "CASEIN_MOB_DEV_NOTIFICATION_JSON",
      Jason.encode!(%{
        "source" => "push",
        "data" => %{
          "action" => "mobile.needs_review",
          "card_id" => "needs_review:ws-1:run-1",
          "card_type" => "needs_review"
        }
      })
    )

    view = mount_screen(SessionDashboardScreen)

    assert assigns(view).pending_notification_card_id == "needs_review:ws-1:run-1"
    assert text(view) =~ "Review card will open after cards refresh"
  end

  test "invalid dev notification JSON is ignored at launch" do
    System.put_env("CASEIN_MOB_DEV_NOTIFICATION_JSON", "{not-json")

    view = mount_screen(SessionDashboardScreen)

    assert assigns(view).pending_notification_card_id == nil
    refute text(view) =~ "Review card will open after cards refresh"
  end

  test "mobile card stream auth error clears stale cards" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "cards" => [
             %{
               "id" => "needs_review:ws-1:run-1",
               "type" => "needs_review",
               "priority" => "high",
               "workspace_id" => "ws-1",
               "title" => "1 item needs review",
               "body" => "Review required before work continues",
               "action" => %{
                 "label" => "Open",
                 "route" => %{"type" => "session_detail", "workspace_id" => "ws-1"}
               }
             }
           ]
         }}
      )

    assert assigns(view).mobile_cards_by_id != %{}
    assert text(view) =~ "1 item needs review"

    view = render_info(view, {:mobile_cards_status, {:error, :unauthorized}})

    assert assigns(view).mobile_cards_by_id == %{}
    assert assigns(view).mobile_cards == []
    assert text(view) =~ "Pairing needs attention"
    assert text(view) =~ "Pair again to resume mobile cards"
    refute text(view) =~ "1 item needs review"
  end

  test "needs review dominates a live workspace card" do
    SessionConfig.put_pairing("https://casein.test", "token")
    SessionConfig.pin_workspace("ws-1")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:session_snapshot, "ws-1", snapshot(%{"pending_reviews" => 4})})
      |> render_info({:session_status, "ws-1", :joined})

    assert_renderable(view)
    assert text(view) =~ "Live"
    assert text(view) =~ "Review required before work continues"
    assert find(view, :button, text: "4 items need review")
    assert find(view, :button, text: "Open")
    assert find(view, :button, text: "...")
  end

  test "review callout routes to workspace detail" do
    SessionConfig.put_pairing("https://casein.test", "token")
    SessionConfig.pin_workspace("ws-1")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:session_snapshot, "ws-1", snapshot(%{"pending_reviews" => 2})})
      |> render_info({:tap, {:open, "ws-1"}})

    assert navigated_to(view) == CaseinMob.SessionDetailScreen
    assert SessionConfig.resume_context() == %{workspace_id: "ws-1", source: :workspace}
  end

  test "running card shows current work and active agents" do
    SessionConfig.put_pairing("https://casein.test", "token")
    SessionConfig.pin_workspace("ws-1")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info(
        {:session_snapshot, "ws-1",
         snapshot(%{
           "current_run" => %{"status" => "started", "command_id" => "deploy-production"},
           "active_agents" => [%{"tool" => "reviewer"}, %{"tool" => "tester"}]
         })}
      )
      |> render_info({:session_status, "ws-1", :joined})

    assert text(view) =~ "Running deploy-production"
    assert text(view) =~ "2 agents active"
    assert text(view) =~ "Run started"
    assert text(view) =~ "Agents: reviewer, tester"
    assert text(view) =~ "Last activity"
  end

  test "offline card makes retry primary and keeps cached open available" do
    SessionConfig.put_pairing("https://casein.test", "token")
    SessionConfig.pin_workspace("ws-1")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:session_status, "ws-1", :disconnected})

    assert_renderable(view)
    assert find(view, :button, text: "Offline")
    assert find(view, :button, text: "Offline").props.height == 44.0
    assert find(view, :button, text: "Offline").props.background == :surface_raised
    assert text(view) =~ "Last seen unknown"
    assert text(view) =~ "Workspace may be offline or network changed"
    assert find(view, :button, text: "Retry")
    assert find(view, :button, text: "Retry").props.height == 44.0
    assert find(view, :button, text: "Open")
  end

  test "network disconnect explains connection recovery" do
    SessionConfig.put_pairing("https://casein.test", "token")
    SessionConfig.pin_workspace("ws-1")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:session_status, "ws-1", {:disconnected, :network_unavailable}})

    assert_renderable(view)
    assert find(view, :button, text: "Network")
    assert find(view, :button, text: "Network").props.height == 44.0
    assert text(view) =~ "Network unavailable"
    assert text(view) =~ "Check your connection and retry"
    assert find(view, :button, text: "Retry")
    assert find(view, :button, text: "Open")
  end

  test "retry shows optimistic reconnect feedback and clears resolved notice" do
    SessionConfig.put_pairing("https://casein.test", "token")
    SessionConfig.pin_workspace("ws-1")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:session_status, "ws-1", :disconnected})
      |> render_info({:tap, {:retry, "ws-1"}})

    assert assigns(view).statuses["ws-1"] == :connecting
    assert text(view) =~ "Reconnecting ws-1..."
    assert text(view) =~ "Joining workspace feed"
    assert find(view, :progress)

    view = render_info(view, {:session_status, "ws-1", :joined})

    assert text(view) =~ "ws-1 is live"

    view = render_info(view, {:clear_notice, "ws-1 is live"})
    refute text(view) =~ "ws-1 is live"
  end

  test "error card offers retry and pair again" do
    SessionConfig.put_pairing("https://casein.test", "token")
    SessionConfig.pin_workspace("ws-1")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:session_status, "ws-1", :error})

    assert_renderable(view)
    assert find(view, :button, text: "Error")
    assert find(view, :button, text: "Error").props.height == 44.0
    assert find(view, :button, text: "Error").props.background == :red_400
    assert text(view) =~ "Could not join session"
    assert text(view) =~ "Pairing may have expired or token is invalid"
    assert find(view, :button, text: "Retry")
    assert find(view, :button, text: "Pair again")
  end

  test "auth error makes pair again the primary recovery action" do
    SessionConfig.put_pairing("https://casein.test", "token")
    SessionConfig.pin_workspace("ws-1")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:session_status, "ws-1", {:error, :unauthorized}})

    assert_renderable(view)
    assert find(view, :button, text: "Auth")
    assert find(view, :button, text: "Auth").props.height == 44.0
    assert text(view) =~ "Pairing needs attention"
    assert text(view) =~ "access was revoked"
    assert find(view, :button, text: "Pair again").props.background == :primary
    assert find(view, :button, text: "Retry").props.background == :surface_raised
  end

  test "missing workspace error makes unpin the primary recovery action" do
    SessionConfig.put_pairing("https://casein.test", "token")
    SessionConfig.pin_workspace("ws-1")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:session_status, "ws-1", {:error, :workspace_not_found}})

    assert_renderable(view)
    assert find(view, :button, text: "Missing")
    assert find(view, :button, text: "Missing").props.height == 44.0
    assert text(view) =~ "Workspace not found"
    assert text(view) =~ "deleted or moved"
    assert find(view, :button, text: "Unpin").props.background == :primary
    assert find(view, :button, text: "Pair again").props.background == :surface_raised
  end

  test "unpin removes a workspace from the dashboard" do
    SessionConfig.put_pairing("https://casein.test", "token")
    SessionConfig.pin_workspace("ws-1")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:tap, {:unpin, "ws-1"}})

    assert SessionConfig.pinned_workspaces() == []
    assert assigns(view).pinned == []
    assert text(view) =~ "Removed ws-1"
  end

  test "unpair clears pairing and pinned workspaces" do
    SessionConfig.put_pairing("https://casein.test", "token")
    SessionConfig.pin_workspace("ws-1")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "cards" => [
             %{
               "id" => "needs_review:ws-1:run-1",
               "type" => "needs_review",
               "priority" => "high",
               "workspace_id" => "ws-1",
               "title" => "1 item needs review"
             }
           ]
         }}
      )
      |> render_info({:tap, :unpair})

    assert SessionConfig.pairing() == :error
    assert SessionConfig.pinned_workspaces() == []
    refute assigns(view).paired?
    assert assigns(view).mobile_cards_by_id == %{}
    assert assigns(view).mobile_cards == []
    assert text(view) =~ "Host removed"
    refute text(view) =~ "1 item needs review"
  end

  test "long workspace names are truncated on the card" do
    wid = "workspace-with-a-very-long-human-hostile-identifier"
    SessionConfig.put_pairing("https://casein.test", "token")
    SessionConfig.pin_workspace(wid)

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:session_status, wid, :joined})

    assert text(view) =~ "workspace-with-a-very-long-..."
    refute text(view) =~ wid
  end

  test "hydrating cannot consume render-ready and authoritative empty emits once across replay and remount" do
    ConnectionTiming.reset()
    on_exit(fn -> ConnectionTiming.reset() end)

    SessionConfig.put_pairing("http://127.0.0.1:1", "token")
    {:ok, profile} = SessionConfig.connection()
    start_supervised!({SessionClient, test_mode?: true})
    context = :sys.get_state(SessionClient).assigns.timing_context
    telemetry_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:casein, :mobile, :feed, :stage],
        fn _event, measurements, metadata, subscriber ->
          send(subscriber, {:feed_stage, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    hydrating_payload =
      ConnectionTiming.decorate_snapshot(
        %{
          "version" => 1,
          "origin" => %{"id" => profile.origin_id, "display_name" => "Devbox"},
          "cards" => [],
          "live_work" => %{"status" => "hydrating"}
        },
        context
      )

    first_view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:mobile_cards_snapshot, hydrating_payload})

    client_state = :sys.get_state(SessionClient)
    assert client_state.assigns.render_ready_generation == nil
    refute_receive {:feed_stage, _measurements, %{stage: :first_cards_render_ready}}

    authoritative_payload =
      put_in(hydrating_payload, ["live_work", "status"], "authoritative")

    first_view =
      render_info(first_view, {:mobile_cards_snapshot, authoritative_payload})

    client_state = :sys.get_state(SessionClient)
    assert client_state.assigns.render_ready_generation == context.generation

    assert_receive {:feed_stage, %{card_count: 0, duration_ms: duration_ms},
                    %{stage: :first_cards_render_ready, connection_generation: generation}}

    assert duration_ms >= 0
    assert generation == context.generation

    _first_view = render_info(first_view, {:mobile_cards_snapshot, authoritative_payload})
    _client_state = :sys.get_state(SessionClient)

    _remounted_view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:mobile_cards_snapshot, authoritative_payload})

    _client_state = :sys.get_state(SessionClient)
    refute_receive {:feed_stage, _measurements, %{stage: :first_cards_render_ready}}
  end

  defp put_origin_pairing(origin_id) do
    SessionConfig.put_pairing(%{
      origin_id: origin_id,
      display_name: "Devbox",
      url: "https://casein.test",
      token: "token"
    })
  end

  defp mobile_cards_snapshot(origin_id, cards, live_work_status \\ "authoritative") do
    %{
      "origin" => %{"id" => origin_id, "display_name" => "Devbox"},
      "live_work" => %{"status" => live_work_status},
      "cards" => cards
    }
  end

  defp workspace_idle_card(origin_id) do
    card_id = "workspace_idle:ws-1:run-9"

    %{
      "id" => card_id,
      "type" => "workspace_idle",
      "kind" => "workspace_idle",
      "status" => "idle",
      "workspace_id" => "ws-1",
      "session_id" => "run-9",
      "title" => "Workspace idle",
      "origin" => %{"id" => origin_id, "display_name" => "Devbox"},
      "resume" => %{
        "card_id" => card_id,
        "origin" => %{"id" => origin_id, "display_name" => "Devbox"},
        "locator" => %{
          "origin_id" => origin_id,
          "workspace_id" => "ws-1",
          "session_id" => "run-9"
        }
      },
      "actions" => [
        %{
          "id" => "resume",
          "label" => "Resume session",
          "route" => %{
            "type" => "session_detail",
            "workspace_id" => "ws-1",
            "session_id" => "run-9"
          }
        }
      ],
      "action" => %{
        "label" => "Resume",
        "route" => %{
          "type" => "session_detail",
          "workspace_id" => "ws-1",
          "session_id" => "run-9"
        }
      }
    }
  end

  defp start_session_client_probe do
    test_pid = self()
    probe = spawn(fn -> session_client_probe(test_pid) end)
    true = Process.register(probe, SessionClient)
    on_exit(fn -> send(probe, :stop) end)
    probe
  end

  defp session_client_probe(test_pid) do
    receive do
      {:"$gen_cast", message} ->
        send(test_pid, {:session_client_cast, message})
        session_client_probe(test_pid)

      :stop ->
        :ok
    end
  end

  defp snapshot(attrs) do
    Map.merge(
      %{
        "current_run" => nil,
        "pending_reviews" => 0,
        "recent_audit" => [],
        "active_agents" => [],
        "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      },
      attrs
    )
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp assert_no_nil_children(%{children: children}) do
    refute Enum.any?(children, &is_nil/1)
    Enum.each(children, &assert_no_nil_children/1)
  end

  defp assert_no_nil_children(_node), do: :ok
end
