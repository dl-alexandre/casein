defmodule CaseinMob.SessionDashboardScreen do
  @moduledoc """
  Glanceable overview of the workspaces pinned to this device. Watches each
  pinned `session:<workspace_id>` via `CaseinMob.SessionClient` and renders one
  live card per workspace — mode, current-run status, pending reviews, and the
  last policy decision. Tapping a card opens `CaseinMob.SessionDetailScreen`.

  Empty until the device is paired (QR scan from the web cockpit) and at least
  one workspace is pinned. Snapshot payloads are JSON-decoded (string keys).
  Simulator smoke runs may pass `CASEIN_MOB_DEV_NOTIFICATION_JSON` with the
  same normalized push payload shape that the native bridges deliver.
  """
  use Mob.Screen

  alias CaseinMob.ConnectionTiming
  alias CaseinMob.PairingScreen
  alias CaseinMob.ReviewDecisionScreen
  alias CaseinMob.SessionClient
  alias CaseinMob.SessionConfig
  alias CaseinMob.SessionDetailScreen

  @transition_notice_ms 1_600

  @card_segments [
    {:needs_action, "Needs Me"},
    {:running, "Live"},
    {:failed, "Failed"},
    {:done, "Done"}
  ]
  @push_token_timeout_ms 15_000
  @dev_notification_env "CASEIN_MOB_DEV_NOTIFICATION_JSON"

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
      |> Mob.Socket.assign(:cached_cards, SessionConfig.inactive_cached_cards())
      |> Mob.Socket.assign(:mobile_cards_status, :connecting)
      |> Mob.Socket.assign(:push_status, :not_requested)
      |> Mob.Socket.assign(:push_token, nil)
      |> Mob.Socket.assign(:push_error_reason, nil)
      |> Mob.Socket.assign(:push_request_platform, nil)
      |> Mob.Socket.assign(:push_user_registered?, false)
      |> Mob.Socket.assign(:push_user_registration_pending?, false)
      |> Mob.Socket.assign(:push_registered_workspace_ids, MapSet.new())
      |> Mob.Socket.assign(:pending_notification_card_id, nil)
      |> Mob.Socket.assign(:pending_origin_resume, nil)
      |> Mob.Socket.assign(:pending_origin_switch_observation?, false)
      |> Mob.Socket.assign(:pending_refresh_failure_reported?, false)
      |> Mob.Socket.assign(:filter, :needs_action)
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
    {:noreply, accept_mobile_snapshot(socket, payload)}
  end

  def handle_info({:mobile_cards_status, status}, socket) do
    socket =
      socket
      |> maybe_report_refresh_failure(status)
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
    {:noreply, Mob.Socket.push_screen(socket, CaseinMob.TerminalScreen)}
  end

  def handle_info({:alert, :open_apps}, socket) do
    {:noreply, Mob.Socket.push_screen(socket, CaseinMob.HomeScreen)}
  end

  def handle_info({:tap, {:open, wid}}, socket) do
    {:noreply, open_workspace(socket, wid)}
  end

  def handle_info({:tap, {:mobile_card_action, card_id}}, socket) do
    card = find_mobile_card(socket, card_id)
    {:noreply, handle_mobile_card_action(socket, card)}
  end

  def handle_info({:tap, {:filter, key}}, socket) do
    {:noreply, Mob.Socket.assign(socket, :filter, key)}
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

  def handle_info({:tap, {:switch_host, origin_id}}, socket) when is_binary(origin_id) do
    {:noreply, switch_host(socket, origin_id)}
  end

  def handle_info({:tap, :unpair}, socket) do
    Enum.each(socket.assigns.pinned, &SessionClient.unwatch(&1, self()))
    SessionClient.unwatch_mobile_cards(self())
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
     |> Mob.Socket.assign(:notice, "Host removed")
     |> assign_pairing()}
  end

  def handle_info({:clear_notice, message}, %{assigns: %{notice: message}} = socket) do
    {:noreply, Mob.Socket.assign(socket, :notice, nil)}
  end

  def handle_info({:clear_notice, _message}, socket), do: {:noreply, socket}

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Render ──────────────────────────────────────────────────────────────────

  def render(assigns) do
    %{
      type: :column,
      props: %{background: :background, fill_width: true, fill_height: true},
      children:
        [
          header(),
          notice(assigns.notice),
          %{
            type: :scroll,
            props: %{fill_width: true, weight: 1},
            children: [
              %{
                type: :column,
                props: %{fill_width: true, padding: :space_md, gap: 10},
                children: dashboard_body(assigns)
              }
            ]
          }
        ]
        |> Enum.reject(&is_nil/1)
    }
  end

  defp header do
    %{
      type: :row,
      props: %{fill_width: true, background: :primary, padding: :space_sm, gap: 8},
      children: [
        %{
          type: :text,
          props: %{
            text: "Attention Inbox",
            text_size: :xl,
            text_color: :on_primary,
            weight: 1,
            font_weight: "bold"
          },
          children: []
        },
        %{
          type: :button,
          props: %{
            text: "+ Pair",
            background: :surface_raised,
            text_color: :on_surface,
            fill_width: false,
            padding: :space_sm,
            height: 44.0,
            on_tap: {self(), :pair_device}
          },
          children: []
        },
        %{
          type: :button,
          props: %{
            text: "...",
            background: :surface_raised,
            text_color: :on_surface,
            fill_width: false,
            padding: :space_sm,
            height: 44.0,
            on_tap: {self(), :root_menu}
          },
          children: []
        }
      ]
    }
  end

  defp dashboard_body(%{pinned: [], paired?: false}) do
    [
      saved_hosts_section(SessionConfig.host_profiles(), :disconnected),
      empty_state(
        "Not paired yet",
        "Pair this phone with a workspace to watch runs, reviews, and agent activity from anywhere.",
        "+ Pair workspace",
        :pair_device
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp dashboard_body(%{pinned: [], paired?: true} = assigns) do
    ([
       paired_summary(assigns),
       saved_hosts_section(assigns.host_profiles, assigns.mobile_cards_status)
     ] ++
       mobile_cards_status_banner(assigns) ++
       push_status_banner(assigns) ++
       observer_section(assigns) ++
       empty_workspace_state(mobile_cards(assigns)))
    |> Enum.reject(&is_nil/1)
  end

  defp dashboard_body(assigns) do
    ([
       paired_summary(assigns),
       saved_hosts_section(assigns.host_profiles, assigns.mobile_cards_status)
     ] ++
       mobile_cards_status_banner(assigns) ++
       push_status_banner(assigns) ++
       observer_section(assigns) ++
       Enum.map(assigns.pinned, fn wid ->
         card(
           wid,
           Map.get(assigns.snapshots, wid),
           Map.get(assigns.statuses, wid, :connecting),
           assigns.host_name
         )
       end))
    |> Enum.reject(&is_nil/1)
  end

  defp paired_summary(%{paired?: true, host_url: host_url, host_name: host_name} = assigns) do
    %{
      type: :column,
      props: %{fill_width: true, background: :surface, padding: :space_sm, gap: 4},
      children:
        [
          %{
            type: :text,
            props: %{
              text: "#{host_name} · #{connection_health_label(assigns.mobile_cards_status)}",
              text_color: :on_surface,
              text_size: :lg,
              font_weight: "bold"
            },
            children: []
          },
          resume_button(assigns[:resume_context], host_name),
          %{
            type: :button,
            props: %{
              text: "Unpair",
              fill_width: false,
              background: :surface_raised,
              text_color: :on_surface,
              padding: :space_sm,
              on_tap: {self(), :unpair}
            },
            children: []
          },
          muted_line(host_url),
          muted_line(connection_health_copy(assigns.mobile_cards_status)),
          %{
            type: :text,
            props: %{
              text: push_debug_line(assigns),
              text_color: :muted,
              text_size: :xs
            },
            children: []
          }
        ]
        |> Enum.reject(&is_nil/1)
    }
  end

  defp paired_summary(_assigns), do: nil

  defp saved_hosts_section([_ | _] = profiles, active_status) do
    %{
      type: :column,
      props: %{fill_width: true, background: :surface, padding: :space_sm, gap: 6},
      children: [
        %{
          type: :text,
          props: %{
            text: "Saved hosts",
            text_color: :on_surface,
            text_size: :sm,
            font_weight: "bold"
          },
          children: []
        }
        | Enum.map(profiles, &saved_host_row(&1, active_status))
      ]
    }
  end

  defp saved_hosts_section(_profiles, _active_status), do: nil

  defp saved_host_row(
         %{
           origin_id: origin_id,
           display_name: display_name,
           url: url,
           active?: active?,
           read_only?: read_only?,
           last_workspace_id: last_workspace_id
         },
         active_status
       ) do
    %{
      type: :column,
      props: %{fill_width: true, gap: 2},
      children: [
        saved_host_control(origin_id, display_name, active?, read_only?, active_status),
        muted_line(host_context_line(url, last_workspace_id))
      ]
    }
  end

  defp saved_host_control(_origin_id, display_name, _active?, true, _active_status) do
    %{
      type: :text,
      props: %{
        text: "Legacy · #{display_name} · Re-pair required",
        fill_width: true,
        background: :surface_raised,
        text_color: :muted,
        padding: :space_sm
      },
      children: []
    }
  end

  defp saved_host_control(origin_id, display_name, active?, false, _active_status) do
    %{
      type: :button,
      props: %{
        text: "#{if(active?, do: "Selected", else: "Switch to")} · #{display_name}",
        fill_width: true,
        background: if(active?, do: :surface_raised, else: :primary),
        text_color: if(active?, do: :on_surface, else: :on_primary),
        padding: :space_sm,
        on_tap: {self(), {:switch_host, origin_id}}
      },
      children: []
    }
  end

  defp resume_button(%{workspace_id: workspace_id}, host_name) when is_binary(workspace_id) do
    %{
      type: :button,
      props: %{
        text: "Resume #{host_name} work",
        fill_width: true,
        background: :surface_raised,
        text_color: :on_surface,
        padding: :space_sm,
        on_tap: {self(), :resume_last_session}
      },
      children: []
    }
  end

  defp resume_button(_context, _host_name), do: nil

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

  defp connection_health_label(status) do
    case {status_state(status), status_reason(status)} do
      {:joined, _reason} ->
        "Live"

      {:connecting, _reason} ->
        "Connecting"

      {:disconnected, _reason} ->
        "Offline"

      {:error, reason} when reason in [:unauthorized, :auth_expired, :token_revoked] ->
        "Pair again"

      {:error, _reason} ->
        "Unavailable"

      _ ->
        "Status unknown"
    end
  end

  defp connection_health_copy(status) do
    case {status_state(status), status_reason(status)} do
      {:joined, _reason} ->
        "Authenticated live feed"

      {:connecting, _reason} ->
        "Saved profile · validating live access"

      {:disconnected, _reason} ->
        "Saved profile · live feed offline"

      {:error, reason} when reason in [:unauthorized, :auth_expired, :token_revoked] ->
        "Saved profile · authentication failed"

      {:error, _reason} ->
        "Saved profile · live feed unavailable"

      _ ->
        "Saved profile · connection health unknown"
    end
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
        [
          %{
            type: :column,
            props: %{
              fill_width: true,
              background: status_color(status),
              padding: :space_sm,
              gap: 2
            },
            children: [
              %{
                type: :text,
                props: %{
                  text: title,
                  text_color: :on_surface,
                  text_size: :sm,
                  font_weight: "bold"
                },
                children: []
              },
              %{
                type: :text,
                props: %{text: body, text_color: :on_surface, text_size: :xs},
                children: []
              }
            ]
          }
        ]
    end
  end

  defp mobile_cards_status_banner(_assigns), do: []

  defp push_status_banner(%{paired?: true, push_status: status} = assigns) do
    case push_status_copy(status, assigns[:push_error_reason]) do
      nil ->
        []

      {title, body} ->
        [
          %{
            type: :column,
            props: %{fill_width: true, background: :surface_raised, padding: :space_sm, gap: 2},
            children: [
              %{
                type: :text,
                props: %{
                  text: title,
                  text_color: :on_surface,
                  text_size: :sm,
                  font_weight: "bold"
                },
                children: []
              },
              %{
                type: :text,
                props: %{text: body, text_color: :muted, text_size: :xs},
                children: []
              }
              | push_status_actions(status)
            ]
          }
        ]
    end
  end

  defp push_status_banner(_assigns), do: []

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
      %{
        type: :row,
        props: %{fill_width: true, gap: 8},
        children: [
          action_button("Open Settings", :open_notification_settings, :primary,
            weight: 2,
            text_color: :on_primary
          ),
          action_button("Retry", :retry_push_permission, :surface, weight: 1)
        ]
      }
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

  defp empty_state(title, body, cta, tap, footnote \\ nil) do
    %{
      type: :column,
      props: %{fill_width: true, padding: :space_lg, gap: 10},
      children:
        [
          %{
            type: :text,
            props: %{text: title, text_color: :on_surface, text_size: :lg, font_weight: "bold"},
            children: []
          },
          %{
            type: :text,
            props: %{text: body, text_color: :muted, text_size: :sm},
            children: []
          },
          footnote &&
            %{
              type: :text,
              props: %{text: footnote, text_color: :muted, text_size: :xs},
              children: []
            },
          %{
            type: :button,
            props: %{
              text: cta,
              fill_width: true,
              background: :primary,
              text_color: :on_primary,
              padding: :space_md,
              on_tap: {self(), tap}
            },
            children: []
          }
        ]
        |> Enum.reject(&is_nil/1)
    }
  end

  defp card(wid, snap, status, host_name) do
    state = card_state(snap, status)
    pending = pending_count(snap)

    %{
      type: :column,
      props: %{
        fill_width: true,
        background: :surface,
        padding: :space_md,
        padding_bottom: :space_sm,
        gap: 8
      },
      children:
        [
          muted_line("#{host_name} · #{display_workspace(wid)}"),
          card_header(wid, status),
          primary_status(state, snap, status),
          review_callout(wid, pending),
          run_progress_line(snap),
          agents_line(snap),
          secondary_context(state, snap),
          card_actions(wid, state, status)
        ]
        |> Enum.reject(&is_nil/1)
    }
  end

  # Action-first section: segmented filter + priority-sorted cards for the active
  # segment, with an actionable empty state when the segment is clear.
  defp observer_section(assigns) do
    active = Map.get(assigns, :filter, :needs_action)

    body =
      case filtered_sorted_cards(assigns, active) do
        [] -> [filter_empty_state(active, assigns)]
        cards -> Enum.map(cards, &observer_card(&1, assigns))
      end

    [filter_segments(active) | body]
  end

  defp filtered_sorted_cards(assigns, active) do
    assigns
    |> mobile_cards()
    |> Enum.filter(&(card_segment(&1) == active))
    |> Enum.sort_by(&priority_rank/1)
  end

  defp mobile_cards(assigns) do
    live = assigns |> Map.get(:mobile_cards, []) |> Enum.filter(&is_map/1)
    cached = assigns |> Map.get(:cached_cards, []) |> Enum.filter(&is_map/1)
    live ++ cached
  end

  defp filter_segments(active) do
    %{
      type: :row,
      props: %{fill_width: true, gap: 6},
      children:
        Enum.map(@card_segments, fn {key, label} ->
          selected? = key == active

          %{
            type: :button,
            props: %{
              text: label,
              weight: 1,
              height: 40.0,
              padding: :space_sm,
              text_size: :sm,
              background: if(selected?, do: :primary, else: :surface_raised),
              text_color: if(selected?, do: :on_primary, else: :on_surface),
              on_tap: {self(), {:filter, key}}
            },
            children: []
          }
        end)
    }
  end

  defp filter_empty_state(active, assigns)
       when active in [:needs_action, :running] do
    if live_work_hydrating?(assigns) do
      empty_notice(
        "Syncing live work",
        "Casein is loading the authoritative state for this origin."
      )
    else
      settled_filter_empty_state(active)
    end
  end

  defp filter_empty_state(active, _assigns), do: settled_filter_empty_state(active)

  defp settled_filter_empty_state(:needs_action),
    do:
      empty_notice(
        "Nothing needs you",
        "Decisions and human blockers land here. Open Live to follow active work."
      )

  defp settled_filter_empty_state(:running),
    do:
      empty_notice(
        "No live work observed",
        "Active agent work appears here after an authoritative refresh."
      )

  defp settled_filter_empty_state(:failed),
    do: empty_notice("No failures", "Connection issues and failed runs surface here.")

  defp settled_filter_empty_state(:done),
    do: empty_notice("Nothing here yet", "Idle workspaces and finished work land here.")

  defp empty_notice(title, body) do
    %{
      type: :column,
      props: %{fill_width: true, background: :surface, padding: :space_md, gap: 4},
      children: [
        %{
          type: :text,
          props: %{text: title, text_color: :on_surface, font_weight: "bold"},
          children: []
        },
        %{type: :text, props: %{text: body, text_color: :muted, text_size: :sm}, children: []}
      ]
    }
  end

  # Segment classification reads the normalized `kind`/`status`, falling back to
  # the legacy `type` for compatibility.
  defp card_segment(card) do
    required_decision = card |> get("attention", %{}) |> get("required_decision")
    resume_state = card |> get("resume", %{}) |> get("state") |> to_string()
    kind = to_string(get(card, "kind") || get(card, "type") || "")
    status = to_string(get(card, "status") || "")

    if is_binary(required_decision) and required_decision != "" do
      :needs_action
    else
      case resume_segment(resume_state) do
        nil -> legacy_card_segment(kind, status)
        segment -> segment
      end
    end
  end

  defp resume_segment("needs_attention"), do: :needs_action
  defp resume_segment("working"), do: :running
  defp resume_segment("failed"), do: :failed
  defp resume_segment("ready_to_review"), do: :needs_action
  defp resume_segment("completed"), do: :done
  defp resume_segment(_state), do: nil

  defp legacy_card_segment(kind, status) do
    cond do
      kind in ["approval_required", "needs_review"] -> :needs_action
      kind == "in_progress" -> :running
      kind == "connection_issue" -> :failed
      kind == "workspace_idle" -> :done
      status in ["resolved", "done"] -> :done
      true -> :needs_action
    end
  end

  defp priority_rank(card) do
    attention = get(card, "attention", %{})
    rank = get(attention, "rank", 0)

    {
      attention_priority_rank(get(attention, "priority") || get(card, "priority")),
      if(is_integer(rank), do: rank * -1, else: 0),
      attention_recency_rank(card),
      to_string(get(attention, "identity") || get(card, "qualified_id") || get(card, "id"))
    }
  end

  defp attention_recency_rank(card) do
    attention_changed = card |> get("attention", %{}) |> get("changed_at")

    latest_change =
      card
      |> get("attention", %{})
      |> get("since_viewed", %{})
      |> get("changes", [])
      |> List.wrap()
      |> List.first()
      |> then(fn
        change when is_map(change) -> get(change, "occurred_at")
        _change -> nil
      end)

    attention_changed
    |> Kernel.||(latest_change)
    |> Kernel.||(get(card, "updated_at"))
    |> Kernel.||(get(card, "_cached_at"))
    |> timestamp_rank()
  end

  defp timestamp_rank(%DateTime{} = value), do: -DateTime.to_unix(value, :microsecond)

  defp timestamp_rank(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> -DateTime.to_unix(parsed, :microsecond)
      _error -> 0
    end
  end

  defp timestamp_rank(_value), do: 0

  defp card_action_notice({:ok, _result}), do: "Action accepted"
  defp card_action_notice({:error, reason}), do: "Action failed: #{humanize_reason(reason)}"

  defp humanize_reason(reason) when is_binary(reason), do: String.replace(reason, "_", " ")
  defp humanize_reason(reason), do: inspect(reason)

  defp observer_card(card, assigns) do
    workspace_id = get(card, "workspace_id")
    card_id = get(card, "id")
    cached? = get(card, "_cached") == true
    tap_id = if(cached?, do: get(card, "qualified_id"), else: card_id)
    origin_name = card_origin_name(card) || assigns.host_name
    authoritative? = status_state(assigns.mobile_cards_status) == :joined

    tappable? =
      is_binary(tap_id) and not is_nil(card_action_tap(card)) and
        (cached? or authoritative?)

    %{
      type: :column,
      props: %{fill_width: true, background: :surface, padding: :space_md, gap: 8},
      children:
        [
          %{
            type: :row,
            props: %{fill_width: true, gap: 8},
            children: [
              %{
                type: :text,
                props: %{
                  text: get(card, "title", "Mobile update"),
                  text_color: :on_surface,
                  text_size: :lg,
                  font_weight: "bold",
                  weight: 1
                },
                children: []
              },
              chip(
                attention_priority_label(card),
                card_priority_color(
                  get(get(card, "attention", %{}), "priority") || get(card, "priority")
                )
              )
            ]
          },
          attention_reason_line(card),
          since_viewed_line(card),
          card_body(card),
          workspace_id &&
            muted_line(card_context_line(origin_name, workspace_id, card, authoritative?)),
          evidence_summary_line(card),
          action_button(
            if(cached?, do: "Switch & refresh", else: action_label(card)),
            {:mobile_card_action, tap_id},
            :primary,
            fill_width: true,
            text_color: :on_primary,
            disabled: not tappable?
          )
        ]
        |> Enum.reject(&is_nil/1)
    }
  end

  defp empty_workspace_state([]) do
    [
      empty_state(
        "No workspace pinned",
        "This phone is paired to your account, but you haven't pinned a workspace yet.",
        "+ Pair workspace",
        :pair_device,
        "Currently supports one workspace at a time."
      )
    ]
  end

  defp empty_workspace_state(_cards), do: []

  defp live_work_hydrating?(assigns) do
    assigns
    |> Map.get(:mobile_cards_snapshot, %{})
    |> get("live_work", %{})
    |> get("status")
    |> Kernel.==("hydrating")
  end

  defp card_body(card) do
    case get(card, "body") do
      body when is_binary(body) and body != "" ->
        %{type: :text, props: %{text: body, text_color: :muted, text_size: :sm}, children: []}

      _ ->
        nil
    end
  end

  defp evidence_summary_line(card) do
    evidence = get(card, "evidence", %{})
    changed = get(evidence, "changed_files", %{})
    count = get(changed, "count", 0)
    artifact = get(get(evidence, "artifact", %{}), "filename")
    cached? = get(card, "_cached") == true

    parts =
      [
        if(is_integer(count) and count > 0,
          do: "#{count} changed #{if(count == 1, do: "file", else: "files")}"
        ),
        if(is_binary(artifact) and artifact != "", do: "artifact: #{artifact}"),
        if(cached? and is_map(evidence) and map_size(evidence) > 0,
          do: "cached evidence · read-only"
        )
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: muted_line(Enum.join(parts, " · "))
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

  defp card_priority_color("high"), do: :amber_400
  defp card_priority_color(:high), do: :amber_400
  defp card_priority_color("critical"), do: :amber_400
  defp card_priority_color(_priority), do: :surface_raised

  defp attention_priority_rank("critical"), do: 0
  defp attention_priority_rank("high"), do: 1
  defp attention_priority_rank("normal"), do: 2
  defp attention_priority_rank("low"), do: 3
  defp attention_priority_rank(:high), do: 1
  defp attention_priority_rank(_priority), do: 4

  defp attention_priority_label(card) do
    attention = get(card, "attention", %{})

    case get(attention, "required_decision") do
      decision when is_binary(decision) and decision != "" -> decision
      _ -> card_type_label(get(card, "type"))
    end
  end

  defp attention_reason_line(card) do
    case get(get(card, "attention", %{}), "explanation") do
      explanation when is_binary(explanation) and explanation != "" ->
        %{
          type: :text,
          props: %{
            text: "Why now: " <> explanation,
            text_color: :on_surface,
            text_size: :sm,
            font_weight: "bold"
          },
          children: []
        }

      _ ->
        nil
    end
  end

  defp since_viewed_line(card) do
    since = card |> get("attention", %{}) |> get("since_viewed", %{})
    count = get(since, "count", 0)
    changes = get(since, "changes", []) |> List.wrap()
    latest = List.first(changes)

    cond do
      not is_integer(count) or count <= 0 ->
        nil

      is_map(latest) ->
        muted_line(
          "#{count} #{if(count == 1, do: "change", else: "changes")} since you looked · " <>
            to_string(get(latest, "label", "Status changed"))
        )

      true ->
        muted_line("#{count} changes since you looked")
    end
  end

  defp card_header(wid, status) do
    %{
      type: :row,
      props: %{fill_width: true, gap: 8},
      children: [
        %{
          type: :text,
          props: %{
            text: display_workspace(wid),
            text_color: :on_surface,
            font_weight: "bold",
            weight: 1
          },
          children: []
        },
        status_pill(wid, status)
      ]
    }
  end

  defp notice(nil), do: nil

  defp notice(message) do
    %{
      type: :text,
      props: %{
        text: message,
        fill_width: true,
        background: :surface_raised,
        text_color: :on_surface,
        text_size: :sm,
        padding: :space_sm
      },
      children: []
    }
  end

  defp primary_status(:connecting, _snap, _status) do
    connecting_status_block("Connecting...", "Joining workspace feed")
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
    %{
      type: :column,
      props: %{fill_width: true, gap: 2},
      children:
        [
          %{
            type: :text,
            props: %{text: title, text_color: :on_surface, text_size: :lg, font_weight: "bold"},
            children: []
          },
          subtitle &&
            %{
              type: :text,
              props: %{text: subtitle, text_color: :muted, text_size: :sm},
              children: []
            }
        ]
        |> Enum.reject(&is_nil/1)
    }
  end

  defp connecting_status_block(title, subtitle) do
    %{
      type: :column,
      props: %{fill_width: true, gap: 4},
      children: [
        %{
          type: :row,
          props: %{fill_width: true, gap: 8},
          children: [
            %{type: :progress, props: %{color: :primary}, children: []},
            %{
              type: :text,
              props: %{text: title, text_color: :on_surface, text_size: :lg, font_weight: "bold"},
              children: []
            }
          ]
        },
        %{
          type: :text,
          props: %{text: subtitle, text_color: :muted, text_size: :sm},
          children: []
        }
      ]
    }
  end

  defp review_callout(wid, count) when count > 0 do
    %{
      type: :column,
      props: %{fill_width: true, background: :amber_400, padding: :space_sm, gap: 2},
      children: [
        %{
          type: :button,
          props: %{
            text: "#{count} #{plural(count, "item", "items")} need review",
            fill_width: true,
            background: :amber_400,
            text_color: :on_surface,
            text_size: :lg,
            font_weight: "bold",
            padding: 0,
            on_tap: {self(), {:open, wid}}
          },
          children: []
        },
        %{
          type: :text,
          props: %{
            text: "Review required before work continues",
            text_color: :on_surface,
            text_size: :sm
          },
          children: []
        }
      ]
    }
  end

  defp review_callout(_wid, _count), do: nil

  defp run_progress_line(snap) do
    case current_run(snap) do
      %{} = run ->
        muted_line("Run #{run_status_label(run)} · #{run_time_label(run)}")

      _ ->
        nil
    end
  end

  defp agents_line(snap) do
    agents =
      snap
      |> get("active_agents", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    case agents do
      [] ->
        nil

      _ ->
        muted_line("Agents: #{agent_names(agents)}")
    end
  end

  defp secondary_context(:error, _snap), do: nil
  defp secondary_context(:offline, _snap), do: nil

  defp secondary_context(_state, snap) do
    muted_line(last_activity_label(snap))
  end

  defp muted_line(text) do
    %{
      type: :text,
      props: %{text: text, text_color: :muted, text_size: :xs},
      children: []
    }
  end

  defp card_actions(wid, :connecting, _status) do
    %{
      type: :row,
      props: %{fill_width: true, gap: 8},
      children: [
        action_button("Open", {:open, wid}, :surface, weight: 3, disabled: true),
        action_button("...", {:menu, wid}, :surface, weight: 1)
      ]
    }
  end

  defp card_actions(wid, :offline, _status) do
    %{
      type: :row,
      props: %{fill_width: true, gap: 8},
      children: [
        action_button("Retry", {:retry, wid}, :primary, weight: 2, text_color: :on_primary),
        action_button("Open", {:open, wid}, :surface_raised, weight: 2),
        action_button("...", {:menu, wid}, :surface, weight: 1)
      ]
    }
  end

  defp card_actions(wid, :error, status) do
    children =
      case status_reason(status) do
        :workspace_not_found ->
          [
            action_button("Unpin", {:unpin, wid}, :primary, weight: 2, text_color: :on_primary),
            action_button("Pair again", {:pair_again, wid}, :surface_raised, weight: 2),
            action_button("...", {:menu, wid}, :surface, weight: 1)
          ]

        reason
        when reason in [
               :workspace_scope_mismatch,
               :unauthorized,
               :auth_expired,
               :token_revoked
             ] ->
          [
            action_button("Pair again", {:pair_again, wid}, :primary,
              weight: 2,
              text_color: :on_primary
            ),
            action_button("Retry", {:retry, wid}, :surface_raised, weight: 2),
            action_button("...", {:menu, wid}, :surface, weight: 1)
          ]

        _ ->
          [
            action_button("Retry", {:retry, wid}, :primary, weight: 2, text_color: :on_primary),
            action_button("Pair again", {:pair_again, wid}, :surface_raised, weight: 2),
            action_button("...", {:menu, wid}, :surface, weight: 1)
          ]
      end

    %{
      type: :row,
      props: %{fill_width: true, gap: 8},
      children: children
    }
  end

  defp card_actions(wid, _state, _status) do
    %{
      type: :row,
      props: %{fill_width: true, gap: 8},
      children: [
        action_button("Open", {:open, wid}, :primary, weight: 3, text_color: :on_primary),
        action_button("...", {:menu, wid}, :surface, weight: 1)
      ]
    }
  end

  defp action_button(label, tap, background, opts) do
    props = %{
      text: label,
      background: background,
      text_color: Keyword.get(opts, :text_color, :on_surface),
      padding: :space_sm,
      height: 44.0,
      disabled: Keyword.get(opts, :disabled, false),
      on_tap: {self(), tap}
    }

    props =
      if Keyword.has_key?(opts, :weight) do
        Map.put(props, :weight, Keyword.fetch!(opts, :weight))
      else
        props
      end

    props =
      if Keyword.has_key?(opts, :fill_width) do
        Map.put(props, :fill_width, Keyword.fetch!(opts, :fill_width))
      else
        props
      end

    %{
      type: :button,
      props: props,
      children: []
    }
  end

  defp status_pill(wid, status) do
    case status_state(status) do
      state when state in [:disconnected, :error] ->
        %{
          type: :button,
          props: %{
            text: status_label(status),
            background: status_color(status),
            text_color: :on_surface,
            text_size: :xs,
            padding_left: :space_sm,
            padding_right: :space_sm,
            padding_top: 8,
            padding_bottom: 8,
            height: 44.0,
            on_tap: {self(), {:retry, wid}}
          },
          children: []
        }

      _ ->
        chip(status_label(status), status_color(status))
    end
  end

  defp chip(text, color) do
    %{
      type: :text,
      props: %{
        text: text,
        text_size: :xs,
        text_color: :on_surface,
        background: color,
        padding_left: :space_sm,
        padding_right: :space_sm,
        padding_top: 4,
        padding_bottom: 4
      },
      children: []
    }
  end

  defp assign_pairing(socket) do
    socket =
      socket
      |> Mob.Socket.assign(:host_profiles, SessionConfig.host_profiles())
      |> Mob.Socket.assign(:cached_cards, SessionConfig.inactive_cached_cards())

    case SessionConfig.connection() do
      {:ok, %{url: url, display_name: display_name, origin_id: origin_id}} ->
        socket
        |> Mob.Socket.assign(:paired?, true)
        |> Mob.Socket.assign(:origin_id, origin_id)
        |> Mob.Socket.assign(:host_url, display_host(url))
        |> Mob.Socket.assign(:host_name, display_name)

      :error ->
        socket
        |> Mob.Socket.assign(:paired?, false)
        |> Mob.Socket.assign(:origin_id, nil)
        |> Mob.Socket.assign(:host_url, nil)
        |> Mob.Socket.assign(:host_name, nil)
    end
  end

  defp switch_host(socket, origin_id) do
    Enum.each(socket.assigns.pinned, &SessionClient.unwatch(&1, self()))
    SessionClient.unwatch_mobile_cards(self())

    case SessionClient.activate_origin(origin_id) do
      :ok ->
        pinned = SessionConfig.pinned_workspaces()
        Enum.each(pinned, &SessionClient.watch(&1, self()))
        SessionClient.watch_mobile_cards(self())

        socket
        |> Mob.Socket.assign(:pinned, pinned)
        |> Mob.Socket.assign(:snapshots, %{})
        |> Mob.Socket.assign(:statuses, %{})
        |> clear_mobile_cards()
        |> Mob.Socket.assign(:mobile_cards_status, :connecting)
        |> Mob.Socket.assign(:pending_origin_switch_observation?, true)
        |> Mob.Socket.assign(:pending_refresh_failure_reported?, false)
        |> Mob.Socket.assign(:resume_context, SessionConfig.resume_context())
        |> reset_push_state()
        |> Mob.Socket.assign(:notice, "Switched origin; refreshing authoritative state")
        |> assign_pairing()

      :error ->
        Mob.Socket.assign(socket, :notice, "Saved host is no longer available")
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

  defp host_context_line(url, nil), do: display_host(url)

  defp host_context_line(url, workspace_id) do
    "#{display_host(url)} · Last work: #{display_workspace(workspace_id)}"
  end

  defp card_origin_name(card) do
    card |> get("origin", %{}) |> get("display_name")
  end

  defp card_context_line(origin_name, workspace_id, card, authoritative?) do
    base = "#{origin_name || "Origin"} · Workspace #{display_workspace(workspace_id)}"

    cond do
      get(card, "_cached") == true ->
        "#{base} · Cached #{get(card, "_cached_at", "earlier")} · Read-only"

      not authoritative? ->
        "#{base} · Last known · Offline · Read-only"

      true ->
        "#{base} · Live"
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

  defp find_mobile_card(socket, card_id) do
    Map.get(socket.assigns.mobile_cards_by_id, card_id) ||
      Enum.find(socket.assigns.cached_cards, fn card ->
        get(card, "qualified_id") == card_id
      end)
  end

  defp handle_mobile_card_action(socket, nil), do: socket

  defp handle_mobile_card_action(socket, card) do
    if get(card, "_cached") == true do
      begin_cached_resume(socket, card)
    else
      handle_live_mobile_card_action(socket, card)
    end
  end

  defp handle_live_mobile_card_action(socket, card) do
    mark_attention_viewed(card)

    if needs_review_card?(card) or intervention_card?(card) do
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

  defp mark_attention_viewed(card) do
    attention = get(card, "attention", %{})
    since = get(attention, "since_viewed", %{})
    origin_id = card |> get("origin", %{}) |> get("id")
    marker = get(since, "through_marker")
    attention_key = get(attention, "key")
    card_id = get(card, "id")

    if is_binary(origin_id) and is_binary(attention_key) and is_binary(card_id) and
         is_integer(marker) do
      SessionClient.attention_viewed(%{
        "origin_id" => origin_id,
        "card_id" => card_id,
        "attention_key" => attention_key,
        "through_marker" => marker
      })
    end
  end

  defp begin_cached_resume(socket, card) do
    origin_id = card |> get("origin", %{}) |> get("id")

    pending = %{
      origin_id: origin_id,
      card_id: get(card, "id"),
      locator: card |> get("resume", %{}) |> get("locator", %{}),
      workspace_id: get(card, "workspace_id"),
      session_id: get(card, "session_id"),
      cached_at: get(card, "_cached_at")
    }

    begin_origin_resume(socket, pending)
  end

  defp begin_origin_resume(socket, %{origin_id: origin_id} = pending)
       when is_binary(origin_id) do
    if Enum.any?(SessionConfig.host_profiles(), &(&1.origin_id == origin_id)) do
      socket
      |> Mob.Socket.assign(:pending_origin_resume, pending)
      |> switch_host(origin_id)
    else
      socket
      |> Mob.Socket.assign(:pending_origin_resume, nil)
      |> Mob.Socket.assign(:notice, "Unknown origin; nothing was opened")
    end
  end

  defp begin_origin_resume(socket, _pending) do
    socket
    |> Mob.Socket.assign(:pending_origin_resume, nil)
    |> Mob.Socket.assign(:notice, "Push did not identify a trusted saved origin")
  end

  defp complete_pending_origin_resume(
         %{assigns: %{pending_origin_resume: %{origin_id: origin_id} = pending}} = socket
       ) do
    if socket.assigns[:origin_id] == origin_id do
      socket = Mob.Socket.assign(socket, :pending_origin_resume, nil)

      case Map.get(socket.assigns.mobile_cards_by_id, pending.card_id) do
        card when is_map(card) ->
          observe_resume("locator_fallback", "succeeded", pending, fallback_level: "exact")

          handle_live_mobile_card_action(socket, card)

        _ ->
          observe_resume("locator_fallback", "failed", pending, fallback_level: "exact")
          open_locator_fallback(socket, pending)
      end
    else
      socket
    end
  end

  defp complete_pending_origin_resume(socket), do: socket

  defp open_locator_fallback(socket, pending) do
    locator = pending[:locator] || %{}
    workspace_id = get(locator, "workspace_id") || pending[:workspace_id]
    session_id = get(locator, "session_id") || pending[:session_id]

    if is_binary(workspace_id) do
      fallback_level = if(is_binary(session_id), do: "task_session", else: "workspace")

      observe_resume("locator_fallback", "succeeded", pending, fallback_level: fallback_level)

      open_resume_context(socket, %{
        workspace_id: workspace_id,
        session_id: session_id,
        source: :origin_resume
      })
    else
      observe_resume("locator_fallback", "unavailable", pending, fallback_level: "action_center")

      Mob.Socket.assign(socket, :notice, "Origin refreshed; open its Action Center")
    end
  end

  defp card_action_tap(card) do
    if get(card, "_cached") == true do
      origin_id = card |> get("origin", %{}) |> get("id")
      if is_binary(origin_id), do: {:activate_resume, origin_id}
    else
      live_card_action_tap(card)
    end
  end

  defp live_card_action_tap(card) do
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

  defp accept_mobile_snapshot(socket, payload) do
    descriptor = get(payload, "origin")

    case accept_snapshot_origin(descriptor) do
      {:ok, origin_id} ->
        cards =
          payload
          |> snapshot_cards()
          |> List.wrap()
          |> Enum.filter(&is_map/1)

        cards_by_id =
          cards
          |> Map.new(fn card -> {get(card, "id"), card} end)
          |> Map.reject(fn {id, _card} -> is_nil(id) end)

        _ = SessionConfig.cache_cards(origin_id, cards, snapshot_observed_at(cards))

        socket
        |> Mob.Socket.assign(:mobile_cards_snapshot, payload)
        |> Mob.Socket.assign(:mobile_cards, cards)
        |> Mob.Socket.assign(:mobile_cards_by_id, cards_by_id)
        |> refresh_pairing_and_push()
        |> maybe_register_push_for_known_workspaces()
        |> observe_origin_switch_if_pending(origin_id)
        |> maybe_open_pending_notification()
        |> complete_pending_origin_resume()
        |> report_first_cards_render_ready(payload, length(cards))

      {:error, reason} ->
        socket
        |> Mob.Socket.assign(:notice, origin_rejection_notice(reason))
        |> Mob.Socket.assign(:pending_origin_resume, nil)
    end
  end

  defp accept_snapshot_origin(descriptor) when is_map(descriptor) do
    case SessionConfig.reconcile_active_origin(descriptor) do
      {:ok, profile} -> {:ok, profile.origin_id}
      {:error, reason} -> {:error, reason}
    end
  end

  # Compatibility with servers predating the descriptor: the already-active,
  # credentialed socket may update its own profile, but can never select another.
  defp accept_snapshot_origin(_descriptor) do
    case SessionConfig.connection() do
      {:ok, profile} -> {:ok, profile.origin_id}
      :error -> {:error, :unknown_origin}
    end
  end

  defp report_first_cards_render_ready(socket, payload, card_count) do
    if authoritative_live_work_snapshot?(payload) do
      case ConnectionTiming.snapshot_generation(payload) do
        generation when is_binary(generation) ->
          :ok = SessionClient.cards_render_ready(generation, card_count)
          socket

        _missing_generation ->
          socket
      end
    else
      socket
    end
  end

  defp authoritative_live_work_snapshot?(payload) do
    payload
    |> get("live_work", %{})
    |> get("status")
    |> Kernel.==("authoritative")
  end

  defp snapshot_observed_at(cards) do
    cards
    |> Enum.map(&get(&1, "updated_at"))
    |> Enum.filter(&is_binary/1)
    |> Enum.max(fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)
  end

  defp origin_rejection_notice(:origin_mismatch), do: "Origin mismatch; state was not accepted"
  defp origin_rejection_notice(_reason), do: "Unknown origin; state was not accepted"

  defp needs_review_card?(card), do: get(card, "type") in ["needs_review", :needs_review]

  defp intervention_card?(card), do: is_map(get(card, "intervention"))

  defp observe_origin_switch_if_pending(
         %{assigns: %{pending_origin_switch_observation?: true}} = socket,
         _origin_id
       ) do
    SessionClient.mobile_observation(%{
      "event" => "origin_switch",
      "outcome" => "succeeded"
    })

    SessionClient.mobile_observation(%{
      "event" => "authoritative_refresh",
      "outcome" => "succeeded"
    })

    socket
    |> Mob.Socket.assign(:pending_origin_switch_observation?, false)
    |> Mob.Socket.assign(:pending_refresh_failure_reported?, false)
    |> Mob.Socket.assign(:notice, nil)
  end

  defp observe_origin_switch_if_pending(socket, _origin_id), do: socket

  defp maybe_report_refresh_failure(
         %{assigns: %{pending_origin_switch_observation?: true}} = socket,
         status
       ) do
    if status_state(status) == :error and
         socket.assigns.pending_refresh_failure_reported? != true do
      SessionClient.mobile_observation(%{
        "event" => "authoritative_refresh",
        "outcome" => "failed"
      })

      Mob.Socket.assign(socket, :pending_refresh_failure_reported?, true)
    else
      socket
    end
  end

  defp maybe_report_refresh_failure(socket, _status), do: socket

  defp observe_resume(event, outcome, pending, opts) do
    SessionClient.mobile_observation(%{
      "event" => event,
      "outcome" => outcome,
      "fallback_level" => Keyword.get(opts, :fallback_level),
      "stale_age_bucket" => stale_age_bucket(pending[:cached_at]),
      "workspace_id" => pending[:workspace_id],
      "card_id" => pending[:card_id]
    })
  end

  defp stale_age_bucket(cached_at) when is_binary(cached_at) do
    with {:ok, datetime, _offset} <- DateTime.from_iso8601(cached_at) do
      age_seconds = max(DateTime.diff(DateTime.utc_now(), datetime, :second), 0)

      cond do
        age_seconds < 300 -> "under_5m"
        age_seconds < 3_600 -> "under_1h"
        age_seconds < 86_400 -> "under_24h"
        true -> "over_24h"
      end
    else
      _ -> "unknown"
    end
  end

  defp stale_age_bucket(_cached_at), do: "unknown"

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
        "Open system settings for Casein and enable notifications"
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
    origin_id = get(data, "origin_id")

    pairing_code =
      get(data, "pairing_code") || pairing_code_from_deep_link(get(data, "deep_link"))

    cond do
      get(data, "action") == "mobile.pair" and present?(pairing_code) ->
        Mob.Socket.push_screen(socket, PairingScreen, %{code: pairing_code})

      mobile_review_notification?(data) and present?(card_id) ->
        SessionClient.mobile_observation(%{
          "event" => "notification",
          "outcome" => "opened",
          "workspace_id" => get(data, "workspace_id"),
          "card_id" => card_id
        })

        handle_review_notification(socket, data, card_id, origin_id)

      true ->
        socket
    end
  end

  defp handle_review_notification(socket, data, card_id, origin_id)
       when is_binary(origin_id) and origin_id != "" do
    begin_origin_resume(socket, %{
      origin_id: origin_id,
      card_id: card_id,
      locator: notification_locator(data),
      workspace_id: get(data, "workspace_id"),
      session_id: get(data, "session_id")
    })
  end

  defp handle_review_notification(socket, _data, card_id, _origin_id) do
    open_review_from_notification(socket, card_id)
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

  defp notification_locator(data) do
    case get(data, "locator") do
      locator when is_map(locator) ->
        locator

      _ ->
        decode_notification_locator(get(data, "locator_json")) || locator_fields(data)
    end
  end

  defp decode_notification_locator(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, locator} when is_map(locator) -> locator
      _ -> nil
    end
  end

  defp decode_notification_locator(_json), do: nil

  defp locator_fields(data) do
    data
    |> Enum.filter(fn {key, value} ->
      to_string(key) in ~w(
        origin_id workspace_id session_id task_type task_id
        tmux_session window pane tab artifact
      ) and is_binary(value)
    end)
    |> Map.new()
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

  defp review_card_id_from_deep_link(deep_link) when is_binary(deep_link) do
    case URI.parse(deep_link) do
      %URI{scheme: "casein", host: "review", path: "/" <> encoded_card_id}
      when encoded_card_id != "" ->
        URI.decode(encoded_card_id)

      _ ->
        nil
    end
  end

  defp review_card_id_from_deep_link(_deep_link), do: nil

  defp pairing_code_from_deep_link("casein://pair/" <> encoded_code) do
    URI.decode(encoded_code)
  end

  defp pairing_code_from_deep_link(_deep_link), do: nil

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

  defp status_color(status) do
    case status_state(status) do
      :joined -> :green_400
      :connecting -> :amber_400
      :disconnected -> :surface_raised
      :error -> :red_400
      _ -> :surface_raised
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
