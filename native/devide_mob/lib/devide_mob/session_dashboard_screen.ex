defmodule DevideMob.SessionDashboardScreen do
  @moduledoc """
  Glanceable overview of the workspaces pinned to this device. Watches each
  pinned `session:<workspace_id>` via `DevideMob.SessionClient` and renders one
  live card per workspace — mode, current-run status, pending reviews, and the
  last policy decision. Tapping a card opens `DevideMob.SessionDetailScreen`.

  Empty until the device is paired (QR scan from the web cockpit) and at least
  one workspace is pinned. Snapshot payloads are JSON-decoded (string keys).
  Simulator smoke runs may pass `DEVIDE_MOB_DEV_NOTIFICATION_JSON` with the
  same normalized push payload shape that the native bridges deliver.
  """
  use Mob.Screen

  alias DevideMob.SessionConfig
  alias DevideMob.UI
  alias DevideMob.SessionClient
  alias DevideMob.SessionDetailScreen
  alias DevideMob.PairingScreen
  alias DevideMob.ReviewDecisionScreen

  @transition_notice_ms 1_600

  # How many settled/failed cards the "Recent" tier shows before it collapses.
  @recent_preview_limit 3
  @snooze_seconds 3_600
  @push_token_timeout_ms 15_000
  @dev_notification_env "DEVIDE_MOB_DEV_NOTIFICATION_JSON"

  def mount(_params, _session, socket) do
    pinned = SessionConfig.pinned_workspaces()
    Enum.each(pinned, &SessionClient.watch(&1, self()))
    if SessionConfig.pairing() != :error, do: SessionClient.watch_mobile_cards(self())

    socket =
      socket
      |> Mob.Socket.assign(:pinned, pinned)
      |> Mob.Socket.assign(:snapshots, %{})
      |> Mob.Socket.assign(:statuses, %{})
      |> Mob.Socket.assign(:mobile_cards_snapshot, nil)
      |> Mob.Socket.assign(:mobile_cards, [])
      |> Mob.Socket.assign(:mobile_cards_by_id, %{})
      |> Mob.Socket.assign(:mobile_cards_status, :connecting)
      |> Mob.Socket.assign(:push_status, :not_requested)
      |> Mob.Socket.assign(:push_token, nil)
      |> Mob.Socket.assign(:push_error_reason, nil)
      |> Mob.Socket.assign(:push_request_platform, nil)
      |> Mob.Socket.assign(:push_user_registered?, false)
      |> Mob.Socket.assign(:push_user_registration_pending?, false)
      |> Mob.Socket.assign(:push_registered_workspace_ids, MapSet.new())
      |> Mob.Socket.assign(:pending_notification_card_id, nil)
      |> Mob.Socket.assign(:snoozed, SessionConfig.snoozed_cards())
      |> Mob.Socket.assign(:show_all_recent, false)
      |> Mob.Socket.assign(:notice, nil)
      |> Mob.Socket.assign(:menu_workspace, nil)
      |> Mob.Socket.assign(:resume_context, SessionConfig.resume_context())
      |> assign_pairing()
      |> maybe_request_push_permission()
      |> maybe_apply_dev_notification()

    {:ok, socket}
  end

  def handle_info({:session_snapshot, wid, payload}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:snapshots, Map.put(socket.assigns.snapshots, wid, payload))
     |> refresh_pairing_and_push()
     |> maybe_register_push_for_known_workspaces()}
  end

  def handle_info({:session_status, wid, status}, socket) do
    previous_status = Map.get(socket.assigns.statuses, wid)

    {:noreply,
     socket
     |> Mob.Socket.assign(:statuses, Map.put(socket.assigns.statuses, wid, status))
     |> transition_notice(wid, previous_status, status)
     |> refresh_pairing_and_push()
     |> maybe_register_push_for_known_workspaces()}
  end

  def handle_info({:session_alert, wid, payload}, socket) do
    {:noreply, Mob.Alert.toast(socket, alert_message(wid, payload))}
  end

  def handle_info({:mobile_cards_snapshot, payload}, socket) do
    cards =
      payload
      |> snapshot_cards()
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    cards_by_id =
      cards
      |> Map.new(fn card -> {get(card, "id"), card} end)
      |> Map.reject(fn {id, _card} -> is_nil(id) end)

    {:noreply,
     socket
     |> Mob.Socket.assign(:mobile_cards_snapshot, payload)
     |> Mob.Socket.assign(:mobile_cards, cards)
     |> Mob.Socket.assign(:mobile_cards_by_id, cards_by_id)
     |> refresh_pairing_and_push()
     |> maybe_register_push_for_known_workspaces()
     |> maybe_open_pending_notification()}
  end

  def handle_info({:mobile_cards_status, status}, socket) do
    socket =
      socket
      |> maybe_clear_mobile_cards(status)
      |> Mob.Socket.assign(:mobile_cards_status, status)
      |> refresh_pairing_and_push()
      |> maybe_register_push_for_known_workspaces()

    {:noreply, socket}
  end

  def handle_info({:permission, :notifications, :granted}, socket) do
    {:noreply, request_push_token(socket)}
  end

  def handle_info({:permission, :notifications, :denied}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:push_status, :permission_denied)
     |> Mob.Socket.assign(:push_error_reason, :permission_denied)}
  end

  def handle_info({:push_token, platform, token}, socket)
      when platform in [:ios, :android] and is_binary(token) do
    socket =
      socket
      |> Mob.Socket.assign(:push_status, :registration_pending)
      |> Mob.Socket.assign(:push_token, %{platform: Atom.to_string(platform), token: token})
      |> Mob.Socket.assign(:push_error_reason, nil)
      |> Mob.Socket.assign(:push_request_platform, platform)
      |> maybe_register_push_for_known_workspaces()

    {:noreply, socket}
  end

  def handle_info({:push_token_error, platform, reason}, socket)
      when platform in [:ios, :android] do
    {:noreply,
     socket
     |> Mob.Socket.assign(:push_status, :native_unavailable)
     |> Mob.Socket.assign(:push_error_reason, {platform, reason})
     |> Mob.Socket.assign(:push_request_platform, platform)}
  end

  def handle_info(
        :push_token_timeout,
        %{assigns: %{push_status: :registering, push_token: nil}} = socket
      ) do
    {:noreply, native_push_unavailable(socket, push_token_timeout_reason(socket))}
  end

  def handle_info(:push_token_timeout, socket), do: {:noreply, socket}

  def handle_info({:push_registration_status, workspace_id, :registered}, socket)
      when is_binary(workspace_id) do
    registered = socket.assigns.push_registered_workspace_ids || MapSet.new()

    {:noreply,
     socket
     |> Mob.Socket.assign(:push_registered_workspace_ids, MapSet.put(registered, workspace_id))
     |> Mob.Socket.assign(:push_status, :registered)
     |> Mob.Socket.assign(:push_error_reason, nil)}
  end

  def handle_info({:push_registration_status, :user, :registered}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:push_user_registered?, true)
     |> Mob.Socket.assign(:push_user_registration_pending?, false)
     |> Mob.Socket.assign(:push_status, :registered)
     |> Mob.Socket.assign(:push_error_reason, nil)}
  end

  def handle_info({:push_registration_status, scope, {:error, reason}}, socket) do
    status =
      if push_registered?(socket),
        do: :registered,
        else: :registration_failed

    socket =
      if scope == :user do
        Mob.Socket.assign(socket, :push_user_registration_pending?, false)
      else
        socket
      end

    {:noreply,
     socket
     |> Mob.Socket.assign(:push_status, status)
     |> Mob.Socket.assign(:push_error_reason, reason)}
  end

  def handle_info({:notification, payload}, socket) when is_map(payload) do
    {:noreply, handle_notification(socket, payload)}
  end

  def handle_info({:tap, :root_menu}, socket) do
    socket =
      Mob.Alert.action_sheet(socket,
        title: "Sessions",
        buttons: [
          [label: "Terminal", action: :open_terminal],
          [label: "Apps", action: :open_apps],
          [label: "Cancel", style: :cancel]
        ]
      )

    {:noreply, socket}
  end

  def handle_info({:alert, :open_terminal}, socket) do
    {:noreply, Mob.Socket.push_screen(socket, DevideMob.TerminalScreen)}
  end

  def handle_info({:alert, :open_apps}, socket) do
    {:noreply, Mob.Socket.push_screen(socket, DevideMob.HomeScreen)}
  end

  def handle_info({:tap, {:open, wid}}, socket) do
    {:noreply, open_workspace(socket, wid)}
  end

  def handle_info({:tap, {:mobile_card_action, card_id}}, socket) do
    card = Map.get(socket.assigns.mobile_cards_by_id, card_id)
    {:noreply, handle_mobile_card_action(socket, card)}
  end

  # An inline decision submits the server-authored action id straight from the
  # card, without opening the review screen.
  def handle_info({:tap, {:inline_card_action, card_id, action_id}}, socket)
      when is_binary(card_id) and is_binary(action_id) do
    SessionClient.card_action(card_id, action_id)

    {:noreply,
     temporary_notice(socket, "#{inline_action_label(socket, card_id, action_id)} sent")}
  end

  def handle_info({:tap, :show_all_recent}, socket) do
    {:noreply, Mob.Socket.assign(socket, :show_all_recent, true)}
  end

  # Snoozing is device-local and self-expiring: it quiets a card for an hour, it
  # never resolves it. The server's view of the work is untouched.
  def handle_info({:tap, {:snooze, card_id}}, socket) when is_binary(card_id) do
    SessionConfig.snooze_card(card_id, @snooze_seconds)

    {:noreply,
     socket
     |> Mob.Socket.assign(:snoozed, SessionConfig.snoozed_cards())
     |> temporary_notice("Snoozed for 1 hour")}
  end

  def handle_info({:tap, :unsnooze_all}, socket) do
    SessionConfig.unsnooze_all()
    {:noreply, Mob.Socket.assign(socket, :snoozed, SessionConfig.snoozed_cards())}
  end

  def handle_info({:card_action_result, _card_id, result}, socket) do
    {:noreply, temporary_notice(socket, card_action_notice(result))}
  end

  def handle_info({:tap, {:retry, wid}}, socket) do
    {:noreply, retry_workspace(socket, wid)}
  end

  def handle_info({:tap, {:unpin, wid}}, socket) do
    {:noreply, unpin_workspace(socket, wid)}
  end

  def handle_info({:tap, {:pair_again, _wid}}, socket) do
    {:noreply, Mob.Socket.push_screen(socket, PairingScreen)}
  end

  def handle_info({:tap, :resume_last_session}, socket) do
    {:noreply, resume_last_session(socket)}
  end

  def handle_info({:tap, :open_notification_settings}, socket) do
    {:noreply, open_notification_settings(socket)}
  end

  def handle_info({:tap, :retry_push_permission}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:push_status, :not_requested)
     |> Mob.Socket.assign(:push_error_reason, nil)
     |> maybe_request_push_permission()}
  end

  def handle_info({:tap, {:menu, wid}}, socket) do
    socket =
      socket
      |> Mob.Socket.assign(:menu_workspace, wid)
      |> Mob.Alert.action_sheet(
        title: display_workspace(wid),
        buttons: [
          [label: "Retry", action: :retry_workspace],
          [label: "Unpin", style: :destructive, action: :unpin_workspace],
          [label: "Cancel", style: :cancel]
        ]
      )

    {:noreply, socket}
  end

  def handle_info({:alert, :retry_workspace}, %{assigns: %{menu_workspace: wid}} = socket)
      when is_binary(wid) do
    {:noreply, retry_workspace(socket, wid)}
  end

  def handle_info({:alert, :unpin_workspace}, %{assigns: %{menu_workspace: wid}} = socket)
      when is_binary(wid) do
    {:noreply, unpin_workspace(socket, wid)}
  end

  def handle_info({:tap, :pair_device}, socket) do
    {:noreply, Mob.Socket.push_screen(socket, PairingScreen)}
  end

  def handle_info({:tap, :unpair}, socket) do
    Enum.each(socket.assigns.pinned, &SessionClient.unwatch(&1, self()))
    SessionClient.unwatch_mobile_cards(self())
    SessionConfig.clear_all()
    SessionClient.clear_pairing()

    {:noreply,
     socket
     |> Mob.Socket.assign(:pinned, [])
     |> Mob.Socket.assign(:snapshots, %{})
     |> Mob.Socket.assign(:statuses, %{})
     |> clear_mobile_cards()
     |> Mob.Socket.assign(:mobile_cards_status, :disconnected)
     |> Mob.Socket.assign(:resume_context, nil)
     |> reset_push_state()
     |> Mob.Socket.assign(:notice, "Device unpaired")
     |> assign_pairing()}
  end

  def handle_info({:clear_notice, message}, %{assigns: %{notice: message}} = socket) do
    {:noreply, Mob.Socket.assign(socket, :notice, nil)}
  end

  def handle_info({:clear_notice, _message}, socket), do: {:noreply, socket}

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Render ──────────────────────────────────────────────────────────────────
  #
  # Layout is deliberately built from `UI` primitives rather than raw nodes:
  # `gap:` is a no-op in both native renderers, and only Box/Button round their
  # corners, so hand-rolled spacing and rounding silently degrade on device.

  def render(assigns) do
    %{
      type: :column,
      props: %{background: :background, fill_width: true, fill_height: true},
      children:
        [
          header(assigns),
          notice(assigns.notice),
          %{
            type: :scroll,
            props: %{fill_width: true, weight: 1},
            children: [
              UI.stack(dashboard_body(assigns),
                gap: 12,
                padding_left: 16,
                padding_right: 16,
                padding_top: 12,
                padding_bottom: 28
              )
            ]
          }
        ]
        |> Enum.reject(&is_nil/1)
    }
  end

  defp header(assigns) do
    UI.header("Action Center",
      subtitle: header_subtitle(assigns),
      actions: [
        UI.icon_button("qr_code", {self(), :pair_device}, label: "Pair workspace"),
        UI.icon_button("more", {self(), :root_menu}, label: "More")
      ]
    )
  end

  # One line that answers "is this phone connected, and to what?" — the detail
  # (full URL, push diagnostics) lives in the footer, out of the content's way.
  defp header_subtitle(%{paired?: true} = assigns) do
    workspaces = assigns |> mobile_cards() |> Enum.map(&get(&1, "workspace_id")) |> Enum.uniq()
    count = workspaces |> Enum.reject(&is_nil/1) |> length()
    host = assigns[:host_url] |> to_string() |> String.replace(~r{^https?://}, "")

    case count do
      0 -> host
      n -> "#{host} · #{n} #{plural(n, "workspace", "workspaces")}"
    end
  end

  defp header_subtitle(_assigns), do: "Not paired"

  defp dashboard_body(%{pinned: [], paired?: false}) do
    [
      UI.card(
        [
          UI.empty_state(
            "Not paired yet",
            "Pair this phone with a workspace to watch runs, reviews, and agent activity from anywhere.",
            icon: "qr_code",
            cta: "+ Pair workspace",
            on_tap: {self(), :pair_device}
          )
        ],
        padding: 4
      )
    ]
  end

  defp dashboard_body(%{pinned: [], paired?: true} = assigns) do
    mobile_cards_status_banner(assigns) ++
      push_status_banner(assigns) ++
      resume_row(assigns) ++
      observer_section(assigns) ++
      empty_workspace_state(mobile_cards(assigns)) ++
      [paired_footer(assigns)]
  end

  defp dashboard_body(assigns) do
    (mobile_cards_status_banner(assigns) ++
       push_status_banner(assigns) ++
       resume_row(assigns) ++
       observer_section(assigns) ++
       [UI.section_label("Pinned workspaces")] ++
       Enum.map(assigns.pinned, fn wid ->
         card(wid, Map.get(assigns.snapshots, wid), Map.get(assigns.statuses, wid, :connecting))
       end) ++
       [paired_footer(assigns)])
    |> Enum.reject(&is_nil/1)
  end

  # Pairing state and push diagnostics: real information, but not the reason
  # anyone opens this screen. It sits at the bottom in muted type.
  defp paired_footer(%{paired?: true, host_url: host_url} = assigns) do
    UI.stack(
      [
        UI.divider(),
        UI.row(
          [
            UI.meta("Paired to #{host_url}", weight: 1),
            UI.button("Unpair", {self(), :unpair}, :ghost, fill_width: false)
          ],
          gap: 8
        ),
        UI.meta(push_debug_line(assigns))
      ],
      gap: 8,
      padding_top: 8
    )
  end

  defp paired_footer(_assigns), do: nil

  defp resume_row(%{resume_context: %{workspace_id: workspace_id}} = assigns)
       when is_binary(workspace_id) do
    [
      UI.card(
        [
          UI.row(
            [
              UI.stack(
                [
                  UI.meta("Last session"),
                  UI.body(resume_label(assigns[:resume_context]), font_weight: "semibold")
                ],
                gap: 2,
                weight: 1
              ),
              UI.button("Resume", {self(), :resume_last_session}, :secondary, fill_width: false)
            ],
            gap: 8
          )
        ],
        padding: 12
      )
    ]
  end

  defp resume_row(_assigns), do: []

  defp resume_label(%{workspace_id: workspace_id} = context) do
    case Map.get(context, :session_id) do
      session_id when is_binary(session_id) ->
        "#{display_workspace(workspace_id)} · #{truncate(session_id, 18)}"

      _ ->
        display_workspace(workspace_id)
    end
  end

  defp push_debug_line(assigns) do
    token? = if assigns[:push_token], do: "yes", else: "no"
    user? = if assigns[:push_user_registered?], do: "yes", else: "no"

    workspace_count =
      assigns |> Map.get(:push_registered_workspace_ids, MapSet.new()) |> MapSet.size()

    [
      "Push #{format_status(assigns[:push_status])}",
      "token #{token?}",
      "user #{user?}",
      "workspaces #{workspace_count}"
    ]
    |> Enum.join(" · ")
  end

  defp format_status(nil), do: "unknown"
  defp format_status(status) when is_atom(status), do: Atom.to_string(status)
  defp format_status(status) when is_binary(status), do: status

  defp format_status({state, reason}) do
    "#{format_status(state)}:#{format_status(reason)}"
  end

  defp format_status(status), do: inspect(status)

  defp mobile_cards_status_banner(%{paired?: true, mobile_cards_status: status}) do
    case mobile_cards_status_copy(status) do
      nil ->
        []

      {title, body} ->
        [banner(status_tone(status), banner_icon(status), title, body)]
    end
  end

  defp mobile_cards_status_banner(_assigns), do: []

  defp push_status_banner(%{paired?: true, push_status: status} = assigns) do
    case push_status_copy(status, assigns[:push_error_reason]) do
      nil ->
        []

      {title, body} ->
        [banner(:neutral, "info", title, body, push_status_actions(status))]
    end
  end

  defp push_status_banner(_assigns), do: []

  defp banner(tone, icon, title, body, extra \\ []) do
    UI.tinted(
      [
        UI.row(
          [
            UI.icon(icon, text_color: UI.tone_fg(tone), text_size: 15),
            UI.text(title,
              text_size: :sm,
              font_weight: "semibold",
              text_color: :on_surface,
              weight: 1
            )
          ],
          gap: 8
        ),
        UI.meta(body)
      ] ++ extra,
      tone,
      gap: 6
    )
  end

  defp banner_icon(status) do
    case status_state(status) do
      :error -> "error"
      :disconnected -> "warning"
      _ -> "info"
    end
  end

  defp push_status_copy(:native_unavailable, reason) do
    {"Push notifications unavailable", push_unavailable_body(reason)}
  end

  defp push_status_copy(:permission_denied, _reason) do
    {"Push notifications off",
     "Enable notification permission in system settings to receive review alerts"}
  end

  defp push_status_copy(:registration_failed, reason) do
    {"Push registration failed", push_registration_failed_body(reason)}
  end

  defp push_status_copy(_status, _reason), do: nil

  defp push_status_actions(:permission_denied) do
    [
      UI.row(
        [
          UI.button("Open Settings", {self(), :open_notification_settings}, :primary, weight: 2),
          UI.button("Retry", {self(), :retry_push_permission}, :secondary, weight: 1)
        ],
        gap: 8
      )
    ]
  end

  defp push_status_actions(_status), do: []

  defp push_unavailable_body(reason)
       when reason in [:firebase_unconfigured, "firebase_unconfigured"] do
    "Add google-services.json or Firebase build properties to receive FCM alerts"
  end

  defp push_unavailable_body(reason)
       when reason in [:firebase_init_failed, "firebase_init_failed"] do
    "Firebase could not initialize on this device build"
  end

  defp push_unavailable_body(reason)
       when reason in [:firebase_token_unavailable, "firebase_token_unavailable"] do
    "Firebase could not issue a push token on this device"
  end

  defp push_unavailable_body(reason)
       when reason in [:firebase_token_timeout, "firebase_token_timeout"] do
    "Firebase did not return a push token in time"
  end

  defp push_unavailable_body({:ios, reason})
       when reason in [:apns_token_timeout, "apns_token_timeout"] do
    "APNs did not return a push token in time. Check notification permission and the aps-environment entitlement."
  end

  defp push_unavailable_body({:android, reason})
       when reason in [:firebase_token_timeout, "firebase_token_timeout"] do
    "Firebase did not return a push token in time"
  end

  defp push_unavailable_body({:android, reason})
       when reason in [:firebase_token_unavailable, "firebase_token_unavailable"] do
    "Firebase could not issue a push token on this device"
  end

  defp push_unavailable_body({:ios, reason}) do
    "APNs push token request failed: #{format_push_error_reason(reason)}"
  end

  defp push_unavailable_body({:android, reason}) do
    "Firebase push token request failed: #{format_push_error_reason(reason)}"
  end

  defp push_unavailable_body(reason) when is_binary(reason) do
    "Firebase push token request failed: #{reason}"
  end

  defp push_unavailable_body(_reason) do
    "Native push token support is unavailable in this environment"
  end

  defp format_push_error_reason(reason) when is_binary(reason) and reason != "", do: reason
  defp format_push_error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_push_error_reason(_reason), do: "unknown"

  defp push_registration_failed_body(reason) when reason in [:unauthorized, "unauthorized"] do
    "Pair again to register this device for workspace alerts"
  end

  defp push_registration_failed_body(reason)
       when reason in [:push_provider_unconfigured, "push_provider_unconfigured"] do
    "Server push delivery is not configured yet"
  end

  defp push_registration_failed_body(reason)
       when reason in [
              :no_team_id,
              "no_team_id",
              :no_key_id,
              "no_key_id",
              :no_topic,
              "no_topic",
              :no_private_key,
              "no_private_key"
            ] do
    "Server APNs credentials are incomplete"
  end

  defp push_registration_failed_body(reason)
       when reason in [
              :no_project_id,
              "no_project_id",
              :no_access_token_fun,
              "no_access_token_fun",
              :no_service_account,
              "no_service_account"
            ] do
    "Server Firebase credentials are incomplete"
  end

  defp push_registration_failed_body(reason)
       when reason in [
              :invalid_private_key,
              "invalid_private_key",
              :invalid_service_account,
              "invalid_service_account"
            ] do
    "Server push credentials are invalid"
  end

  defp push_registration_failed_body(_reason) do
    "The app will retry after the card stream or workspace feed rejoins"
  end

  defp mobile_cards_status_copy(status) do
    case {status_state(status), status_reason(status)} do
      {:joined, _reason} ->
        nil

      {:connecting, _reason} ->
        {"Card stream connecting", "Waiting for latest observer snapshot"}

      {:disconnected, :network_unavailable} ->
        {"Card stream offline", "Network unavailable; latest mobile cards may be stale"}

      {:disconnected, _reason} ->
        {"Card stream offline", "Latest mobile cards may be stale"}

      {:error, reason} when reason in [:unauthorized, :auth_expired, :token_revoked] ->
        {"Pairing needs attention", "Pair again to resume mobile cards"}

      {:error, _reason} ->
        {"Card stream unavailable", "Cards will refresh after the stream rejoins"}

      _ ->
        nil
    end
  end

  # ── Workspace card ──────────────────────────────────────────────────────────

  defp card(wid, snap, status) do
    state = card_state(snap, status)
    pending = pending_count(snap)

    UI.card(
      [
        card_header(wid, status),
        primary_status(state, snap, status),
        review_callout(wid, pending),
        meta_lines(state, snap),
        card_actions(wid, state, status)
      ],
      tone: state_tone(state)
    )
  end

  defp card_header(wid, status) do
    UI.row(
      [
        UI.dot(state_tone(status_state(status))),
        UI.text(display_workspace(wid),
          text_color: :on_surface,
          font_weight: "semibold",
          text_size: :sm,
          weight: 1
        ),
        status_pill(wid, status)
      ],
      gap: 8
    )
  end

  defp status_pill(wid, status) do
    tone = state_tone(status_state(status))

    case status_state(status) do
      state when state in [:disconnected, :error] ->
        # Tappable: a bad status is also the retry affordance, so it gets a
        # full 44pt target rather than a decorative pill.
        %{
          type: :button,
          props: %{
            text: status_label(status),
            background: UI.tone_tint(tone),
            text_color: UI.tone_fg(tone),
            text_size: :xs,
            font_weight: "semibold",
            corner_radius: :radius_pill,
            fill_width: false,
            padding_left: 12,
            padding_right: 12,
            height: 44.0,
            on_tap: {self(), {:retry, wid}}
          },
          children: []
        }

      _ ->
        UI.chip(status_label(status), tone)
    end
  end

  defp primary_status(:connecting, _snap, _status) do
    UI.row(
      [
        UI.spinner(),
        UI.stack([UI.title("Connecting"), UI.meta("Joining workspace feed")], gap: 2, weight: 1)
      ],
      gap: 10
    )
  end

  defp primary_status(:offline, snap, status) do
    case status_reason(status) do
      :network_unavailable ->
        status_block("Network unavailable", "Check your connection and retry")

      _ ->
        status_block(last_seen_label(snap), "Workspace may be offline or network changed")
    end
  end

  defp primary_status(:error, _snap, status) do
    status_block(problem_title(status), problem_body(status))
  end

  defp primary_status(:needs_review, snap, _status) do
    case current_run(snap) do
      nil -> status_block("Needs review", nil)
      run -> status_block("Running #{command_label(run)}", agent_summary(snap))
    end
  end

  defp primary_status(:running, snap, _status) do
    status_block("Running #{command_label(current_run(snap))}", agent_summary(snap))
  end

  defp primary_status(:idle, _snap, _status) do
    status_block("No active run", nil)
  end

  defp status_block(title, subtitle) do
    UI.stack([UI.title(title), UI.body(subtitle, text_color: :muted)], gap: 3)
  end

  defp review_callout(wid, count) when count > 0 do
    UI.tinted(
      [
        UI.row(
          [
            UI.icon("warning", text_color: UI.tone_fg(:attention), text_size: 15),
            UI.text("#{count} #{plural(count, "item", "items")} need review",
              text_size: :sm,
              font_weight: "semibold",
              text_color: UI.tone_fg(:attention),
              weight: 1
            )
          ],
          gap: 8
        ),
        UI.meta("Review required before work continues")
      ],
      :attention,
      gap: 4,
      padding: 10,
      on_tap: {self(), {:open, wid}}
    )
  end

  defp review_callout(_wid, _count), do: nil

  # Run / agent / activity context, collapsed into one muted line so the card
  # stays scannable instead of becoming a wall of grey text.
  defp meta_lines(state, snap) do
    [
      run_progress_text(snap),
      agents_text(snap),
      secondary_context(state, snap)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> UI.meta(Enum.join(parts, " · "))
    end
  end

  defp run_progress_text(snap) do
    case current_run(snap) do
      %{} = run ->
        status = run_status_label(run)
        time = run_time_label(run)

        # `run_time_label/1` names the timestamp it found ("started 4m ago"),
        # which is usually the status again — don't say it twice.
        if String.starts_with?(time, status),
          do: "Run #{time}",
          else: "Run #{status} · #{time}"

      _ ->
        nil
    end
  end

  defp agents_text(snap) do
    agents =
      snap
      |> get("active_agents", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    case agents do
      [] -> nil
      _ -> "Agents: #{agent_names(agents)}"
    end
  end

  defp secondary_context(:error, _snap), do: nil
  defp secondary_context(:offline, _snap), do: nil
  defp secondary_context(_state, snap), do: last_activity_label(snap)

  defp card_actions(wid, :connecting, _status) do
    UI.row(
      [
        UI.button("Open", {self(), {:open, wid}}, :secondary, weight: 3, disabled: true),
        overflow_button(wid)
      ],
      gap: 8
    )
  end

  defp card_actions(wid, :offline, _status) do
    UI.row(
      [
        UI.button("Retry", {self(), {:retry, wid}}, :primary, weight: 2),
        UI.button("Open", {self(), {:open, wid}}, :secondary, weight: 2),
        overflow_button(wid)
      ],
      gap: 8
    )
  end

  defp card_actions(wid, :error, status) do
    children =
      case status_reason(status) do
        :workspace_not_found ->
          [
            UI.button("Unpin", {self(), {:unpin, wid}}, :primary, weight: 2),
            UI.button("Pair again", {self(), {:pair_again, wid}}, :secondary, weight: 2),
            overflow_button(wid)
          ]

        reason
        when reason in [
               :workspace_scope_mismatch,
               :unauthorized,
               :auth_expired,
               :token_revoked
             ] ->
          [
            UI.button("Pair again", {self(), {:pair_again, wid}}, :primary, weight: 2),
            UI.button("Retry", {self(), {:retry, wid}}, :secondary, weight: 2),
            overflow_button(wid)
          ]

        _ ->
          [
            UI.button("Retry", {self(), {:retry, wid}}, :primary, weight: 2),
            UI.button("Pair again", {self(), {:pair_again, wid}}, :secondary, weight: 2),
            overflow_button(wid)
          ]
      end

    UI.row(children, gap: 8)
  end

  defp card_actions(wid, _state, _status) do
    UI.row(
      [
        UI.button("Open", {self(), {:open, wid}}, :primary, weight: 3),
        overflow_button(wid)
      ],
      gap: 8
    )
  end

  defp overflow_button(wid) do
    UI.icon_button("more", {self(), {:menu, wid}},
      label: "Workspace menu",
      background: :surface_raised
    )
  end

  # ── Attention tiers ─────────────────────────────────────────────────────────
  #
  # Three sections in one scroll rather than four exclusive filter segments.
  # Under segments, a failed run was invisible while you were reading "Needs
  # Action" — nothing actionable should ever be hidden behind a tab. The tail
  # ("Recent") is the only thing that collapses, and only past a few rows.
  #
  #   Needs you — blocked on you, sorted by how long you've been the bottleneck
  #   Running   — work in flight, newest first
  #   Recent    — failures and settled work, newest first, capped
  #
  # Cards move between tiers on their own as their state changes.

  defp observer_section(assigns) do
    now = now_unix()
    tiers = tiered_cards(assigns, now)
    snoozed = snoozed_cards(assigns)

    [
      tier_section(:needs_you, tiers.needs_you, assigns, now),
      tier_section(:running, tiers.running, assigns, now),
      tier_section(:recent, tiers.recent, assigns, now),
      snoozed_footer(snoozed)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp tiered_cards(assigns, now) do
    visible =
      assigns
      |> mobile_cards()
      |> Enum.reject(&snoozed_card?(assigns, &1))

    %{
      # Longest wait first: the point of this tier is "who has been waiting on
      # me the longest", not "what happened most recently".
      needs_you:
        visible
        |> Enum.filter(&(card_tier(&1) == :needs_you))
        |> Enum.sort_by(&{priority_rank(&1), -waiting_seconds(&1, now)}),
      running:
        visible
        |> Enum.filter(&(card_tier(&1) == :running))
        |> Enum.sort_by(&(-card_updated_unix(&1))),
      recent:
        visible
        |> Enum.filter(&(card_tier(&1) == :recent))
        |> Enum.sort_by(&{priority_rank(&1), -card_updated_unix(&1)})
    }
  end

  defp tier_section(tier, cards, assigns, now) do
    expanded? = tier != :recent or Map.get(assigns, :show_all_recent, false)
    shown = if expanded?, do: cards, else: Enum.take(cards, @recent_preview_limit)
    hidden = length(cards) - length(shown)

    body =
      case shown do
        [] -> [tier_empty_state(tier)]
        cards -> Enum.map(cards, &observer_card(&1, now))
      end

    [tier_heading(tier, length(cards)) | body] ++ [show_more_button(tier, hidden)]
  end

  defp tier_heading(tier, 0), do: UI.section_label(tier_label(tier))

  defp tier_heading(tier, count),
    do: UI.section_label("#{tier_label(tier)} · #{count}")

  defp tier_label(:needs_you), do: "Needs you"
  defp tier_label(:running), do: "Running"
  defp tier_label(:recent), do: "Recent"

  defp show_more_button(:recent, hidden) when hidden > 0 do
    UI.button("Show #{hidden} more", {self(), :show_all_recent}, :ghost)
  end

  defp show_more_button(_tier, _hidden), do: nil

  defp tier_empty_state(:needs_you),
    do: empty_notice("Nothing needs your action", "Approvals and blocked runs land here.")

  defp tier_empty_state(:running),
    do: empty_notice("No running work", "Active runs and agents appear here while they work.")

  defp tier_empty_state(:recent), do: nil

  # Which tier a card belongs to. `kind`/`status` are the normalized server
  # fields; `type` is the legacy fallback.
  defp card_tier(card) do
    kind = to_string(get(card, "kind") || get(card, "type") || "")
    status = to_string(get(card, "status") || "")

    cond do
      kind in ["approval_required", "needs_review"] -> :needs_you
      kind == "in_progress" -> :running
      status in ["resolved", "done"] -> :recent
      true -> :recent
    end
  end

  # ── Snooze ──────────────────────────────────────────────────────────────────
  #
  # Device-local and self-expiring (see `SessionConfig.snooze_card/3`): the
  # server owns what is true, the phone owns what it wants to be bothered about
  # right now. A snoozed card is never *deleted* — it comes back on its own.

  defp snoozed_card?(assigns, card) do
    case get(card, "id") do
      id when is_binary(id) -> Map.has_key?(snoozed_map(assigns), id)
      _ -> false
    end
  end

  defp snoozed_cards(assigns) do
    ids = snoozed_map(assigns)

    assigns
    |> mobile_cards()
    |> Enum.filter(fn card ->
      case get(card, "id") do
        id when is_binary(id) -> Map.has_key?(ids, id)
        _ -> false
      end
    end)
  end

  defp snoozed_map(assigns), do: Map.get(assigns, :snoozed, %{})

  defp snoozed_footer([]), do: nil

  defp snoozed_footer(cards) do
    count = length(cards)

    UI.row(
      [
        UI.meta("#{count} snoozed #{plural(count, "card", "cards")}", weight: 1),
        UI.button("Show", {self(), :unsnooze_all}, :ghost, fill_width: false)
      ],
      gap: 8
    )
  end

  # ── Waiting time ────────────────────────────────────────────────────────────
  #
  # Blocked work reports how long *you* have been the bottleneck, not when the
  # last message arrived. "Waiting 2h" is a different call to action than
  # "updated 2h ago".

  defp waiting_seconds(card, now) do
    case card_created_unix(card) do
      nil -> 0
      created -> max(now - created, 0)
    end
  end

  defp waiting_label(card, now) do
    case card_created_unix(card) do
      nil -> nil
      _created -> "Waiting #{duration_label(waiting_seconds(card, now))}"
    end
  end

  defp duration_label(seconds) when seconds < 60, do: "#{max(seconds, 1)}s"
  defp duration_label(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m"
  defp duration_label(seconds) when seconds < 86_400, do: "#{div(seconds, 3_600)}h"
  defp duration_label(seconds), do: "#{div(seconds, 86_400)}d"

  defp card_created_unix(card), do: card |> get("created_at") |> to_unix()
  defp card_updated_unix(card), do: card |> get("updated_at") |> to_unix() || 0

  defp to_unix(value) when is_binary(value) do
    case parse_datetime(value) do
      {:ok, datetime} -> DateTime.to_unix(datetime)
      :error -> nil
    end
  end

  defp to_unix(%DateTime{} = value), do: DateTime.to_unix(value)
  defp to_unix(value) when is_integer(value), do: value
  defp to_unix(_value), do: nil

  defp now_unix, do: DateTime.utc_now() |> DateTime.to_unix()

  defp mobile_cards(assigns) do
    assigns |> Map.get(:mobile_cards, []) |> Enum.filter(&is_map/1)
  end

  defp empty_notice(title, body) do
    UI.card(
      [
        UI.row(
          [
            UI.icon("check", text_color: UI.tone_fg(:done), text_size: 16),
            UI.text(title, text_size: :sm, font_weight: "semibold", text_color: :on_surface)
          ],
          gap: 8
        ),
        UI.meta(body)
      ],
      gap: 6,
      padding: 14
    )
  end

  defp priority_rank(card) do
    case to_string(get(card, "priority") || "") do
      "high" -> 0
      "normal" -> 1
      "low" -> 2
      _ -> 3
    end
  end

  defp inline_action_label(socket, card_id, action_id) do
    socket.assigns.mobile_cards_by_id
    |> Map.get(card_id, %{})
    |> get("actions")
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.find(&(get(&1, "id") == action_id))
    |> case do
      nil -> String.replace(action_id, "_", " ")
      spec -> spec_label(spec)
    end
  end

  defp card_action_notice({:ok, _result}), do: "Action accepted"
  defp card_action_notice({:error, reason}), do: "Action failed: #{humanize_reason(reason)}"

  defp humanize_reason(reason) when is_binary(reason), do: String.replace(reason, "_", " ")
  defp humanize_reason(reason), do: inspect(reason)

  defp observer_card(card, now) do
    tone = card_tone(card)

    UI.card(
      [
        UI.row(
          [
            UI.dot(tone),
            UI.chip(card_type_label(get(card, "type")), tone),
            priority_chip(get(card, "priority")),
            waiting_chip(card, now)
          ],
          gap: 6
        ),
        UI.title(get(card, "title", "Mobile update")),
        UI.body(card_body_text(card), text_color: :muted),
        command_line(card),
        card_meta_line(card),
        card_action_row(card)
      ],
      tone: tone
    )
  end

  # The blocked-time chip only makes sense where you are the bottleneck; on a
  # running or settled card it would just be a second timestamp.
  defp waiting_chip(card, now) do
    if card_tier(card) == :needs_you do
      case waiting_label(card, now) do
        nil -> nil
        label -> UI.chip(label, :neutral)
      end
    end
  end

  # The command itself, not just "1 item needs review". A one-tap approve is
  # only safe if the card says what is being approved.
  defp command_line(card) do
    case card_command(card) do
      nil ->
        nil

      command ->
        UI.box(
          [UI.text(command, text_size: :xs, text_color: :on_surface, font_weight: "medium")],
          background: :surface_raised,
          corner_radius: :radius_sm,
          padding_left: 10,
          padding_right: 10,
          padding_top: 8,
          padding_bottom: 8
        )
    end
  end

  defp card_command(card) do
    [
      get(get(card, "meta"), "command"),
      get(get(card, "meta"), "command_id"),
      get(get(card, "context"), "command_id")
    ]
    |> Enum.find(&(is_binary(&1) and &1 != ""))
    |> case do
      nil -> nil
      command -> truncate(command, 60)
    end
  end

  defp card_meta_line(card) do
    workspace_id = get(card, "workspace_id")

    [
      workspace_id && "Workspace #{display_workspace(workspace_id)}",
      updated_label(card)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> UI.meta(Enum.join(parts, " · "))
    end
  end

  defp updated_label(card) do
    case get(card, "updated_at") do
      value when is_binary(value) -> "updated #{relative_time(value)}"
      _ -> nil
    end
  end

  # Decisions the server already authored (approve / deny / ask agent to fix)
  # are offered on the card itself. Anything that needs typing — a note, a
  # confirmation — still routes into the review screen, so a mis-tap can't
  # deny a run.
  defp card_action_row(card) do
    card_id = get(card, "id")
    tappable? = is_binary(card_id) and not is_nil(card_action_tap(card))
    inline = inline_actions(card)

    open_button =
      UI.button(
        action_label(card),
        {self(), {:mobile_card_action, card_id}},
        open_variant(inline),
        disabled: not tappable?,
        weight: 1
      )

    snooze = snooze_button(card)

    case inline do
      [] ->
        UI.row(Enum.reject([open_button, snooze], &is_nil/1), gap: 8)

      specs ->
        variants = inline_variants(specs)

        UI.stack(
          [
            UI.row(
              specs
              |> Enum.zip(variants)
              |> Enum.map(fn {spec, variant} ->
                UI.button(
                  spec_label(spec),
                  {self(), {:inline_card_action, card_id, get(spec, "id")}},
                  variant,
                  weight: 1
                )
              end),
              gap: 8
            ),
            UI.row(Enum.reject([open_button, snooze], &is_nil/1), gap: 8)
          ],
          gap: 8
        )
    end
  end

  defp snooze_button(card) do
    case get(card, "id") do
      id when is_binary(id) ->
        UI.icon_button("history", {self(), {:snooze, id}},
          label: "Snooze for an hour",
          background: :surface_raised
        )

      _ ->
        nil
    end
  end

  # Inline-able: a server action that needs no input and no confirmation.
  defp inline_actions(card) do
    card
    |> get("actions")
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.filter(fn spec ->
      is_binary(get(spec, "id")) and
        is_nil(get(spec, "route")) and
        is_nil(get(spec, "confirmation")) and
        required_inputs(spec) == []
    end)
    |> Enum.take(2)
  end

  defp required_inputs(spec) do
    spec
    |> get("input", [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&(get(&1, "required") == true))
  end

  defp spec_label(spec) do
    case get(spec, "label") do
      label when is_binary(label) and label != "" -> label
      _ -> get(spec, "id") |> to_string() |> String.replace("_", " ")
    end
  end

  # Every card should have exactly one obvious answer. If the server didn't
  # mark any inline action primary (a lone "Ask agent to fix", say), promote the
  # first one rather than leaving a row of identical grey buttons.
  defp inline_variants(specs) do
    variants = Enum.map(specs, &spec_variant/1)

    if :primary in variants do
      variants
    else
      List.replace_at(variants, 0, :primary)
    end
  end

  defp spec_variant(spec) do
    cond do
      get(spec, "destructive?") == true -> :danger
      get(spec, "style") == "destructive" -> :danger
      get(spec, "style") == "primary" -> :primary
      true -> :secondary
    end
  end

  # With inline decisions present the navigation action steps down a level:
  # the decision is the point of the card, not "open".
  defp open_variant([]), do: :primary
  defp open_variant(_inline), do: :secondary

  defp priority_chip(priority) when priority in ["high", :high],
    do: UI.chip("high", :attention)

  defp priority_chip(_priority), do: nil

  defp empty_workspace_state([]) do
    [
      UI.card(
        [
          UI.empty_state(
            "No workspace pinned",
            "This phone is paired to your account, but you haven't pinned a workspace yet.",
            icon: "add",
            footnote: "Currently supports one workspace at a time.",
            cta: "+ Pair workspace",
            on_tap: {self(), :pair_device}
          )
        ],
        padding: 4
      )
    ]
  end

  defp empty_workspace_state(_cards), do: []

  defp card_body_text(card) do
    case get(card, "body") do
      body when is_binary(body) and body != "" -> body
      _ -> nil
    end
  end

  defp action_label(card) do
    if needs_review_card?(card) do
      "Review"
    else
      case get(get(card, "action"), "label") do
        label when is_binary(label) and label != "" -> label
        _ -> "Open"
      end
    end
  end

  defp card_type_label(type) do
    type
    |> to_string()
    |> String.replace("_", " ")
  end

  # A card's tone is its kind: approvals demand attention, runs are in flight,
  # connection issues and failed runs are failures, idle workspaces are settled.
  defp card_tone(card) do
    case to_string(get(card, "kind") || get(card, "type") || "") do
      kind when kind in ["approval_required", "needs_review"] -> :attention
      "in_progress" -> :running
      kind when kind in ["connection_issue", "run_failed"] -> :failed
      _ -> :done
    end
  end

  defp state_tone(:needs_review), do: :attention
  defp state_tone(:running), do: :running
  defp state_tone(:error), do: :failed
  # Offline is a warning, not a failure: the work is fine, the phone's view of
  # it is stale.
  defp state_tone(:offline), do: :attention
  defp state_tone(:disconnected), do: :attention
  defp state_tone(:connecting), do: :neutral
  defp state_tone(:joined), do: :done
  defp state_tone(_state), do: :neutral

  defp status_tone(status) do
    case status_state(status) do
      :joined -> :done
      :connecting -> :neutral
      :disconnected -> :attention
      :error -> :failed
      _ -> :neutral
    end
  end

  defp notice(nil), do: nil

  defp notice(message) do
    UI.box(
      [UI.text(message, text_color: :on_surface, text_size: :sm)],
      background: :surface_raised,
      fill_width: true,
      padding_left: 16,
      padding_right: 16,
      padding_top: 10,
      padding_bottom: 10
    )
  end

  defp assign_pairing(socket) do
    case SessionConfig.pairing() do
      {:ok, url, _token} ->
        socket
        |> Mob.Socket.assign(:paired?, true)
        |> Mob.Socket.assign(:host_url, display_host(url))

      :error ->
        socket
        |> Mob.Socket.assign(:paired?, false)
        |> Mob.Socket.assign(:host_url, nil)
    end
  end

  defp refresh_pairing_and_push(socket) do
    socket
    |> assign_pairing()
    |> maybe_request_push_permission()
  end

  defp display_host(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(host) ->
        default_port? = (scheme == "http" and port == 80) or (scheme == "https" and port == 443)
        port_suffix = if default_port? or is_nil(port), do: "", else: ":#{port}"
        "#{scheme || "http"}://#{host}#{port_suffix}"

      _ ->
        url
    end
  end

  defp retry_workspace(socket, wid) do
    SessionClient.watch(wid, self())

    socket
    |> Mob.Socket.assign(:statuses, Map.put(socket.assigns.statuses, wid, :connecting))
    |> Mob.Socket.assign(:notice, reconnecting_notice(wid))
    |> Mob.Socket.assign(:menu_workspace, nil)
  end

  defp unpin_workspace(socket, wid) do
    SessionClient.unwatch(wid, self())
    SessionConfig.unpin_workspace(wid)

    socket
    |> Mob.Socket.assign(:pinned, socket.assigns.pinned -- [wid])
    |> Mob.Socket.assign(:snapshots, Map.delete(socket.assigns.snapshots, wid))
    |> Mob.Socket.assign(:statuses, Map.delete(socket.assigns.statuses, wid))
    |> Mob.Socket.assign(:resume_context, SessionConfig.resume_context())
    |> Mob.Socket.assign(:notice, "Removed #{display_workspace(wid)}")
    |> Mob.Socket.assign(:menu_workspace, nil)
  end

  defp handle_mobile_card_action(socket, nil), do: socket

  defp handle_mobile_card_action(socket, card) do
    if needs_review_card?(card) do
      socket
      |> remember_card_context(card)
      |> Mob.Socket.push_screen(ReviewDecisionScreen, %{card: card})
    else
      case card_action_tap(card) do
        {:open, wid} ->
          open_workspace(socket, wid)

        {:retry, wid} ->
          retry_workspace(socket, wid)

        {:pair_again, _wid} ->
          Mob.Socket.push_screen(socket, PairingScreen)

        nil ->
          socket
      end
    end
  end

  defp card_action_tap(card) do
    # Prefer the server's normalized navigation action route; fall back to the
    # legacy `action.route` so older payloads still navigate.
    route = navigation_route(card) || legacy_route(card)
    workspace_id = get(route, "workspace_id") || get(card, "workspace_id")

    case {get(route, "type"), workspace_id} do
      {"retry_workspace", wid} when is_binary(wid) -> {:retry, wid}
      {"pair_workspace", wid} when is_binary(wid) -> {:pair_again, wid}
      {"session_detail", wid} when is_binary(wid) -> {:open, wid}
      {_type, wid} when is_binary(wid) -> {:open, wid}
      _ -> nil
    end
  end

  defp navigation_route(card) do
    card
    |> get("actions")
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.find_value(fn action -> get(action, "route") end)
  end

  defp legacy_route(card), do: card |> get("action") |> get("route")

  defp open_workspace(socket, workspace_id) when is_binary(workspace_id) do
    SessionConfig.put_resume_context(workspace_id)

    socket
    |> Mob.Socket.assign(:resume_context, SessionConfig.resume_context())
    |> Mob.Socket.push_screen(SessionDetailScreen, %{workspace_id: workspace_id})
  end

  defp open_workspace(socket, _workspace_id), do: socket

  defp resume_last_session(socket) do
    case socket.assigns[:resume_context] || SessionConfig.resume_context() do
      %{workspace_id: workspace_id} = context when is_binary(workspace_id) ->
        open_resume_context(socket, context)

      _ ->
        Mob.Socket.assign(socket, :notice, "No session to resume")
    end
  end

  defp open_resume_context(socket, %{workspace_id: workspace_id} = context) do
    SessionConfig.put_resume_context(workspace_id,
      session_id: Map.get(context, :session_id),
      source: Map.get(context, :source, :workspace)
    )

    params =
      %{
        workspace_id: workspace_id,
        session_id: Map.get(context, :session_id),
        source: Map.get(context, :source)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()

    socket
    |> Mob.Socket.assign(:resume_context, SessionConfig.resume_context())
    |> Mob.Socket.push_screen(SessionDetailScreen, params)
  end

  defp remember_card_context(socket, card) do
    workspace_id = get(card, "workspace_id")

    if is_binary(workspace_id) do
      SessionConfig.put_resume_context(workspace_id,
        session_id: get(card, "session_id"),
        source: :review
      )

      Mob.Socket.assign(socket, :resume_context, SessionConfig.resume_context())
    else
      socket
    end
  end

  defp snapshot_cards(payload) when is_map(payload), do: get(payload, "cards", [])
  defp snapshot_cards(_payload), do: []

  defp needs_review_card?(card), do: get(card, "type") in ["needs_review", :needs_review]

  defp maybe_clear_mobile_cards(socket, status) do
    if status_state(status) == :error, do: clear_mobile_cards(socket), else: socket
  end

  defp clear_mobile_cards(socket) do
    socket
    |> Mob.Socket.assign(:mobile_cards_snapshot, nil)
    |> Mob.Socket.assign(:mobile_cards, [])
    |> Mob.Socket.assign(:mobile_cards_by_id, %{})
  end

  defp reset_push_state(socket) do
    socket
    |> Mob.Socket.assign(:push_status, :not_requested)
    |> Mob.Socket.assign(:push_token, nil)
    |> Mob.Socket.assign(:push_error_reason, nil)
    |> Mob.Socket.assign(:push_request_platform, nil)
    |> Mob.Socket.assign(:push_user_registered?, false)
    |> Mob.Socket.assign(:push_user_registration_pending?, false)
    |> Mob.Socket.assign(:push_registered_workspace_ids, MapSet.new())
    |> Mob.Socket.assign(:pending_notification_card_id, nil)
  end

  defp maybe_request_push_permission(
         %{assigns: %{paired?: true, push_status: :not_requested}} = socket
       ) do
    try do
      socket
      |> Mob.Permissions.request(:notifications)
      |> Mob.Socket.assign(:push_status, :permission_requested)
    rescue
      UndefinedFunctionError ->
        native_push_unavailable(socket, :native_missing)

      ErlangError ->
        native_push_unavailable(socket, :native_failed)

      ArgumentError ->
        socket
        |> Mob.Socket.assign(:push_status, :permission_unavailable)
        |> Mob.Socket.assign(:push_error_reason, :permission_unavailable)
    catch
      :exit, _reason ->
        native_push_unavailable(socket, :native_failed)
    end
  end

  defp maybe_request_push_permission(socket), do: socket

  defp open_notification_settings(socket) do
    if native_open_notification_settings() == :ok do
      Mob.Socket.assign(socket, :notice, "Opening notification settings...")
    else
      Mob.Socket.assign(
        socket,
        :notice,
        "Open system settings for DevideMob and enable notifications"
      )
    end
  end

  defp native_open_notification_settings do
    apply(:mob_nif, :open_notification_settings, [])
  rescue
    UndefinedFunctionError -> :error
    ErlangError -> :error
  catch
    :exit, _reason -> :error
  end

  defp request_push_token(socket) do
    case push_runtime_preflight() do
      :ok ->
        try do
          socket =
            socket
            |> MobNotify.register_push()
            |> Mob.Socket.assign(:push_status, :registering)
            |> Mob.Socket.assign(:push_error_reason, nil)
            |> Mob.Socket.assign(:push_request_platform, native_platform(socket))

          Process.send_after(self(), :push_token_timeout, @push_token_timeout_ms)
          socket
        rescue
          UndefinedFunctionError ->
            native_push_unavailable(socket, :native_missing)

          ErlangError ->
            native_push_unavailable(socket, :native_failed)
        catch
          :exit, _reason ->
            native_push_unavailable(socket, :native_failed)
        end

      {:error, reason} ->
        native_push_unavailable(socket, reason)
    end
  end

  defp push_runtime_preflight do
    case System.get_env("MOB_FIREBASE_CONFIGURED") do
      value when value in ["false", "0", "no"] ->
        {:error, env_reason("MOB_FIREBASE_CONFIG_REASON", :firebase_unconfigured)}

      _ ->
        :ok
    end
  end

  defp env_reason(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> value
    end
  end

  defp native_push_unavailable(socket, reason) do
    socket
    |> Mob.Socket.assign(:push_status, :native_unavailable)
    |> Mob.Socket.assign(:push_error_reason, reason)
  end

  defp push_token_timeout_reason(socket) do
    case socket.assigns[:push_request_platform] || native_platform(socket) do
      :ios -> {:ios, :apns_token_timeout}
      :android -> {:android, :firebase_token_timeout}
      _other -> :firebase_token_timeout
    end
  end

  defp native_platform(socket) do
    case get_in(socket.__mob__, [:platform]) do
      platform when platform in [:ios, :android] ->
        platform

      _other ->
        :mob_nif.platform()
    end
  rescue
    _ in [UndefinedFunctionError, ErlangError] -> nil
  catch
    :exit, _reason -> nil
  end

  defp maybe_register_push_for_known_workspaces(%{assigns: %{push_token: nil}} = socket),
    do: socket

  defp maybe_register_push_for_known_workspaces(socket) do
    %{platform: platform, token: token} = socket.assigns.push_token
    registered = socket.assigns.push_registered_workspace_ids || MapSet.new()

    {socket, user_registration_started?} =
      maybe_register_user_push(socket, token, platform)

    ready_ids =
      socket
      |> known_workspace_ids()
      |> Enum.reject(&MapSet.member?(registered, &1))
      |> Enum.filter(&push_registration_ready?(socket, &1))

    Enum.each(ready_ids, fn workspace_id ->
      SessionClient.register_push(workspace_id, token, platform)
    end)

    cond do
      user_registration_started? or ready_ids != [] ->
        Mob.Socket.assign(socket, :push_status, :registering)

      push_registered?(socket) ->
        Mob.Socket.assign(socket, :push_status, :registered)

      true ->
        Mob.Socket.assign(socket, :push_status, :registration_pending)
    end
  end

  defp maybe_register_user_push(socket, token, platform) do
    if socket.assigns.mobile_cards_status == :joined and
         not socket.assigns.push_user_registered? and
         not socket.assigns.push_user_registration_pending? do
      SessionClient.register_user_push(token, platform)

      {Mob.Socket.assign(socket, :push_user_registration_pending?, true), true}
    else
      {socket, false}
    end
  end

  defp push_registered?(socket) do
    socket.assigns.push_user_registered? or
      MapSet.size(socket.assigns.push_registered_workspace_ids || MapSet.new()) > 0
  end

  defp known_workspace_ids(socket) do
    card_workspace_ids =
      socket.assigns.mobile_cards
      |> List.wrap()
      |> Enum.map(&get(&1, "workspace_id"))

    (socket.assigns.pinned ++ card_workspace_ids)
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
  end

  defp push_registration_ready?(socket, workspace_id) do
    socket.assigns.mobile_cards_status == :joined or
      status_state(Map.get(socket.assigns.statuses, workspace_id)) == :joined
  end

  defp handle_notification(socket, payload) do
    data = get(payload, "data", %{})
    card_id = get(data, "card_id") || review_card_id_from_deep_link(get(data, "deep_link"))

    cond do
      mobile_review_notification?(data) and present?(card_id) ->
        open_review_from_notification(socket, card_id)

      true ->
        socket
    end
  end

  defp maybe_apply_dev_notification(socket) do
    case System.get_env(@dev_notification_env) do
      nil ->
        socket

      "" ->
        socket

      json ->
        case Jason.decode(json) do
          {:ok, payload} when is_map(payload) ->
            handle_notification(socket, payload)

          _ ->
            socket
        end
    end
  end

  defp mobile_review_notification?(data) do
    get(data, "action") == "mobile.needs_review" or
      get(data, "card_type") in ["needs_review", :needs_review] or
      review_card_id_from_deep_link(get(data, "deep_link")) != nil
  end

  defp open_review_from_notification(socket, card_id) do
    case Map.get(socket.assigns.mobile_cards_by_id, card_id) do
      card when is_map(card) ->
        socket
        |> remember_card_context(card)
        |> Mob.Socket.push_screen(ReviewDecisionScreen, %{card: card})

      _ ->
        socket
        |> Mob.Socket.assign(:pending_notification_card_id, card_id)
        |> Mob.Socket.assign(:notice, "Review card will open after cards refresh")
    end
  end

  defp maybe_open_pending_notification(
         %{assigns: %{pending_notification_card_id: card_id}} = socket
       )
       when is_binary(card_id) do
    case Map.get(socket.assigns.mobile_cards_by_id, card_id) do
      card when is_map(card) ->
        socket
        |> Mob.Socket.assign(:pending_notification_card_id, nil)
        |> remember_card_context(card)
        |> Mob.Socket.push_screen(ReviewDecisionScreen, %{card: card})

      _ ->
        socket
    end
  end

  defp maybe_open_pending_notification(socket), do: socket

  defp review_card_id_from_deep_link("devide://review/" <> encoded_card_id) do
    URI.decode(encoded_card_id)
  end

  defp review_card_id_from_deep_link(_deep_link), do: nil

  defp card_state(snap, status) do
    case status_state(status) do
      :connecting ->
        :connecting

      :disconnected ->
        :offline

      :error ->
        :error

      _ ->
        cond do
          pending_count(snap) > 0 -> :needs_review
          active_run?(current_run(snap)) -> :running
          true -> :idle
        end
    end
  end

  defp pending_count(snap) when is_map(snap) do
    case get(snap, "pending_reviews", 0) do
      count when is_integer(count) and count > 0 -> count
      _ -> 0
    end
  end

  defp pending_count(_snap), do: 0

  defp current_run(snap) when is_map(snap), do: get(snap, "current_run")
  defp current_run(_snap), do: nil

  defp active_run?(%{} = run) do
    get(run, "status") in ["started", "running", "queued"]
  end

  defp active_run?(_run), do: false

  defp command_label(%{} = run) do
    run
    |> get("command_id")
    |> case do
      nil -> get(run, "command") || get(run, "name") || "command"
      value -> value
    end
    |> to_string()
    |> truncate(34)
  end

  defp command_label(_run), do: "command"

  defp run_status_label(run) do
    run
    |> get("status", "unknown")
    |> to_string()
    |> String.replace("_", " ")
  end

  defp run_time_label(run) do
    [
      {"finished", get(run, "finished_at")},
      {"started", get(run, "started_at")},
      {"requested", get(run, "requested_at")},
      {"updated", get(run, "last_event_at")}
    ]
    |> Enum.find(fn {_label, at} -> present?(at) end)
    |> case do
      {label, at} -> "#{label} #{relative_time(at)}"
      nil -> "timing unknown"
    end
  end

  defp agent_names(agents) do
    {visible, rest} = Enum.split(agents, 3)

    names =
      visible
      |> Enum.map(&agent_name/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(", ")

    suffix =
      case length(rest) do
        0 -> ""
        count -> " +#{count}"
      end

    if names == "", do: "#{length(agents)} active", else: names <> suffix
  end

  defp agent_name(agent) do
    agent
    |> get("tool", get(agent, "source", "agent"))
    |> to_string()
    |> truncate(18)
  end

  defp agent_summary(snap) do
    count =
      snap
      |> get("active_agents", [])
      |> List.wrap()
      |> length()

    if count > 0, do: "#{count} #{plural(count, "agent", "agents")} active", else: nil
  end

  defp last_activity_label(snap) do
    case activity_at(snap) do
      nil -> "Last activity unknown"
      at -> "Last activity #{relative_time(at)}"
    end
  end

  defp last_seen_label(snap) do
    case activity_at(snap) do
      nil -> "Last seen unknown"
      at -> "Last seen #{relative_time(at)}"
    end
  end

  defp activity_at(snap) when is_map(snap) do
    [
      get(current_run(snap), "started_at"),
      get(current_run(snap), "updated_at"),
      get(get(snap, "last_decision"), "at"),
      snap |> get("recent_audit", []) |> List.wrap() |> List.first() |> get("at"),
      get(snap, "updated_at")
    ]
    |> Enum.find(&present?/1)
  end

  defp activity_at(_snap), do: nil

  defp relative_time(%DateTime{} = datetime), do: relative_time(DateTime.to_iso8601(datetime))

  defp relative_time(value) when is_binary(value) do
    case parse_datetime(value) do
      {:ok, datetime} ->
        diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

        cond do
          diff < 60 -> "just now"
          diff < 3_600 -> "#{div(diff, 60)}m ago"
          diff < 86_400 -> "#{div(diff, 3_600)}h ago"
          true -> "#{div(diff, 86_400)}d ago"
        end

      :error ->
        "unknown"
    end
  end

  defp relative_time(_value), do: "unknown"

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp get(map, key, default \\ nil)
  defp get(%{} = map, key, default), do: Map.get(map, key) || atom_key(map, key) || default
  defp get(_map, _key, default), do: default

  defp atom_key(map, key) when is_binary(key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp atom_key(_map, _key), do: nil

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp display_workspace(wid) when is_binary(wid), do: truncate(wid, 30)
  defp display_workspace(_wid), do: "workspace"

  defp truncate(value, limit) when is_binary(value) do
    if String.length(value) > limit do
      value |> String.slice(0, max(limit - 3, 1)) |> Kernel.<>("...")
    else
      value
    end
  end

  defp truncate(value, _limit), do: value

  defp transition_notice(socket, wid, _previous_status, status) do
    case status_state(status) do
      :joined ->
        if reconnecting_notice?(socket.assigns.notice, wid) do
          temporary_notice(socket, "#{display_workspace(wid)} is live")
        else
          socket
        end

      state when state in [:disconnected, :error] ->
        if reconnecting_notice?(socket.assigns.notice, wid) do
          temporary_notice(socket, reconnect_resolution_notice(wid, status))
        else
          socket
        end

      _ ->
        socket
    end
  end

  defp temporary_notice(socket, message) do
    Process.send_after(self(), {:clear_notice, message}, @transition_notice_ms)
    Mob.Socket.assign(socket, :notice, message)
  end

  defp reconnecting_notice?(notice, wid), do: notice == reconnecting_notice(wid)
  defp reconnecting_notice(wid), do: "Reconnecting #{display_workspace(wid)}..."

  defp reconnect_resolution_notice(wid, status) do
    case status_reason(status) do
      :workspace_not_found ->
        "#{display_workspace(wid)} was not found"

      :workspace_scope_mismatch ->
        "Pairing is for another workspace"

      reason when reason in [:unauthorized, :auth_expired, :token_revoked] ->
        "Pair again for #{display_workspace(wid)}"

      :network_unavailable ->
        "Network still unavailable"

      _ ->
        "Still trying to reconnect #{display_workspace(wid)}"
    end
  end

  defp plural(1, singular, _plural), do: singular
  defp plural(_count, _singular, plural), do: plural

  defp alert_message(wid, payload) do
    title = Map.get(payload, "title", "Session alert")
    reason = Map.get(payload, "reason")
    base = "#{wid}: #{title}"
    if is_binary(reason) and reason != "", do: "#{base} (#{reason})", else: base
  end

  defp status_label(status) do
    case {status_state(status), status_reason(status)} do
      {:joined, _} -> "Live"
      {:connecting, _} -> "Connecting"
      {:disconnected, :network_unavailable} -> "Network"
      {:disconnected, _} -> "Offline"
      {:error, :workspace_not_found} -> "Missing"
      {:error, :workspace_scope_mismatch} -> "Pairing"
      {:error, reason} when reason in [:unauthorized, :auth_expired, :token_revoked] -> "Auth"
      {:error, :workspace_unavailable} -> "Unavailable"
      {:error, _} -> "Error"
      _ -> "Unknown"
    end
  end

  defp status_state({state, _reason}) when state in [:joined, :connecting, :disconnected, :error],
    do: state

  defp status_state(%{} = status), do: status |> get("state", :error) |> normalize_state()
  defp status_state(status), do: normalize_state(status)

  defp normalize_state("joined"), do: :joined
  defp normalize_state("connecting"), do: :connecting
  defp normalize_state("disconnected"), do: :disconnected
  defp normalize_state("error"), do: :error
  defp normalize_state(state), do: state

  defp status_reason({_state, reason}), do: normalize_reason(reason)
  defp status_reason(%{} = status), do: status |> get("reason") |> normalize_reason()
  defp status_reason(_status), do: nil

  defp normalize_reason("workspace_not_found"), do: :workspace_not_found
  defp normalize_reason("workspace_scope_mismatch"), do: :workspace_scope_mismatch
  defp normalize_reason("workspace_unavailable"), do: :workspace_unavailable
  defp normalize_reason("unauthorized"), do: :unauthorized
  defp normalize_reason("auth_expired"), do: :auth_expired
  defp normalize_reason("token_revoked"), do: :token_revoked
  defp normalize_reason("network_unavailable"), do: :network_unavailable
  defp normalize_reason("unknown"), do: :unknown
  defp normalize_reason(reason) when is_binary(reason), do: :unknown
  defp normalize_reason(reason), do: reason

  defp problem_title(status) do
    case status_reason(status) do
      :workspace_not_found ->
        "Workspace not found"

      :workspace_scope_mismatch ->
        "Wrong workspace paired"

      :workspace_unavailable ->
        "Workspace unavailable"

      reason when reason in [:unauthorized, :auth_expired, :token_revoked] ->
        "Pairing needs attention"

      _ ->
        "Could not join session"
    end
  end

  defp problem_body(status) do
    case status_reason(status) do
      :workspace_not_found ->
        "This workspace may have been deleted or moved. Unpin it or pair again from the web cockpit."

      :workspace_scope_mismatch ->
        "This phone is paired to a different workspace. Pair again from the correct web cockpit."

      :workspace_unavailable ->
        "The workspace registry could not resolve this workspace. Retry or pair again."

      reason when reason in [:unauthorized, :auth_expired, :token_revoked] ->
        "Your pairing may have expired or access was revoked. Pair again from the web cockpit."

      _ ->
        "Pairing may have expired or token is invalid."
    end
  end
end
