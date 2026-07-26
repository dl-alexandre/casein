defmodule CaseinMob.SessionDashboardScreenTest do
  use Mob.ScreenCase, async: false

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
    assert text(view) =~ "Action Center"
    assert find(view, :button, text: "+ Pair").props.fill_width == false
    assert find(view, :button, text: "...").props.fill_width == false
    assert find(view, :button, text: "...")
    refute find(view, :button, text: "Back")
    refute find(view, :button, text: "Home")
  end

  test "not paired empty state invites pairing" do
    view = mount_screen(SessionDashboardScreen)

    assert_renderable(view)
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
    assert text(view) =~ "casein.test · Connected"
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

    assert find(view, :button, text: "Resume casein.test work")

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
    assert find(view, :button, text: "Connected · casein.test")
    assert text(view) =~ "Last work: mac-ws"

    mac_origin_id = CaseinMob.OriginIdentity.legacy_id("http://192.168.1.72:57585")
    view = render_info(view, {:tap, {:switch_host, mac_origin_id}})

    assert SessionConfig.pairing() ==
             {:ok, "http://192.168.1.72:57585", "mac-token"}

    assert assigns(view).pinned == ["mac-ws"]
    assert assigns(view).push_token == nil
    assert assigns(view).push_registered_workspace_ids == MapSet.new()
    assert text(view) =~ "Switched origin; refreshing authoritative state"
    assert find(view, :button, text: "Connected · Local Mac")

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
    assert assigns(view).notice == "Open system settings for CaseinMob and enable notifications"
    assert text(view) =~ "Open system settings for CaseinMob and enable notifications"
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
    assert text(view) =~ "Card stream offline"
    assert text(view) =~ "Network unavailable"
    assert text(view) =~ "latest mobile cards may be stale"
    assert text(view) =~ "Workspace ws-1 · Last known · Offline · Read-only"
    assert find(view, :button, text: "Review").props.disabled == true
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

    assert find(view, :button, text: "Needs Action")
    assert find(view, :button, text: "Running")

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
  end

  test "an empty segment shows an actionable empty state" do
    SessionConfig.put_pairing("https://casein.test", "token")
    SessionConfig.pin_workspace("ws-1")

    view =
      SessionDashboardScreen
      |> mount_screen()
      |> render_info({:mobile_cards_snapshot, %{"cards" => []}})

    assert text(view) =~ "Nothing needs your action"
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
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "origin" => %{"id" => "origin-local", "display_name" => "Local Mac"},
           "cards" => [card]
         }}
      )
      |> render_info({:tap, {:mobile_card_action, card["id"]}})

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

  test "missing refreshed card falls back to its session and workspace locator" do
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
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "origin" => %{"id" => "origin-mac", "display_name" => "Local Mac"},
           "cards" => []
         }}
      )

    assert navigated_to(view) == CaseinMob.SessionDetailScreen

    assert SessionConfig.resume_context() == %{
             workspace_id: "mac-ws",
             session_id: "session-9",
             source: :origin_resume
           }
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
end
