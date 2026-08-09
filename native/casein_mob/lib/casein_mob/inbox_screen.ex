defmodule CaseinMob.InboxScreen do
  @moduledoc """
  Dedicated companion inbox: ranked `Casein.Mobile.AttentionInbox` projection
  as delivered on `cards_snapshot`, with durable read markers written back
  through `SessionClient.attention_viewed/1`.

  This screen does not re-rank. It preserves server order within each segment
  filter and only uses the attention envelope already attached to each card.
  Opening a card advances the cursor; Needs Me pins stay until the server
  marks the card handled.
  """
  use Mob.Screen

  alias CaseinMob.PairingScreen
  alias CaseinMob.ReviewDecisionScreen
  alias CaseinMob.SessionClient
  alias CaseinMob.SessionConfig
  alias CaseinMob.SessionDetailScreen

  @card_segments [
    {:needs_action, "Needs Me"},
    {:running, "Live"},
    {:failed, "Failed"},
    {:done, "Done"}
  ]

  def mount(_params, _session, socket) do
    if SessionConfig.pairing() != :error, do: SessionClient.watch_mobile_cards(self())

    socket =
      socket
      |> Mob.Socket.assign(:mobile_cards_snapshot, nil)
      |> Mob.Socket.assign(:mobile_cards, [])
      |> Mob.Socket.assign(:mobile_cards_by_id, %{})
      |> Mob.Socket.assign(:cached_cards, SessionConfig.inactive_cached_cards())
      |> Mob.Socket.assign(:mobile_cards_status, initial_status())
      |> Mob.Socket.assign(:filter, :needs_action)
      |> Mob.Socket.assign(:notice, nil)
      |> assign_pairing()

    {:ok, socket}
  end

  def handle_info({:mobile_cards_snapshot, payload}, socket) do
    {:noreply, accept_mobile_snapshot(socket, payload)}
  end

  def handle_info({:mobile_cards_status, status}, socket) do
    socket =
      socket
      |> maybe_clear_mobile_cards(status)
      |> Mob.Socket.assign(:mobile_cards_status, status)
      |> assign_pairing()

    {:noreply, socket}
  end

  def handle_info({:tap, :back}, socket) do
    SessionClient.unwatch_mobile_cards(self())
    {:noreply, Mob.Socket.pop_screen(socket)}
  end

  def handle_info({:tap, :pair_device}, socket) do
    {:noreply, Mob.Socket.push_screen(socket, PairingScreen)}
  end

  def handle_info({:tap, {:filter, key}}, socket)
      when key in [:needs_action, :running, :failed, :done] do
    {:noreply, Mob.Socket.assign(socket, :filter, key)}
  end

  def handle_info({:tap, {:open_card, card_id}}, socket) when is_binary(card_id) do
    card = find_mobile_card(socket, card_id)
    {:noreply, open_card(socket, card)}
  end

  def handle_info({:clear_notice, message}, %{assigns: %{notice: message}} = socket) do
    {:noreply, Mob.Socket.assign(socket, :notice, nil)}
  end

  def handle_info({:clear_notice, _message}, socket), do: {:noreply, socket}

  def handle_info(_message, socket), do: {:noreply, socket}

  def render(assigns), do: CaseinMob.Layout.materialize(build_view(assigns))

  defp build_view(assigns) do
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
                children: body(assigns)
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
          type: :button,
          props: %{
            text: "Back",
            background: :surface_raised,
            text_color: :on_surface,
            fill_width: false,
            padding: :space_sm,
            height: 44.0,
            on_tap: {self(), :back}
          },
          children: []
        },
        %{
          type: :text,
          props: %{
            text: "Inbox",
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
        }
      ]
    }
  end

  defp body(%{paired?: false}) do
    [
      empty_notice(
        "Not paired yet",
        "Pair this phone with a workspace to see what needs you."
      ),
      action_button("Pair workspace", :pair_device, :primary,
        fill_width: true,
        text_color: :on_primary
      )
    ]
  end

  defp body(assigns) do
    status = assigns.mobile_cards_status
    active = Map.get(assigns, :filter, :needs_action)
    cards = filtered_sorted_cards(assigns, active)

    status_block =
      case status_copy(status) do
        nil -> []
        {title, detail} -> [status_banner(title, detail)]
      end

    card_block =
      cond do
        load_failed?(status) and cards == [] ->
          [empty_notice("Inbox could not load", load_failure_detail(status))]

        cards == [] ->
          [filter_empty_state(active, assigns)]

        true ->
          Enum.map(cards, &inbox_card(&1, assigns))
      end

    (status_block ++ [filter_segments(active) | card_block])
    |> Enum.reject(&is_nil/1)
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

  defp filtered_sorted_cards(assigns, active) do
    # Preserve server snapshot order; only filter by segment. Ranking comes from
    # AttentionInbox on the wire — do not invent a second ranker here.
    assigns
    |> mobile_cards()
    |> Enum.filter(&(card_segment(&1) == active))
  end

  defp mobile_cards(assigns) do
    live = assigns |> Map.get(:mobile_cards, []) |> Enum.filter(&is_map/1)
    cached = assigns |> Map.get(:cached_cards, []) |> Enum.filter(&is_map/1)
    live ++ cached
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
        "Inbox is empty",
        "Nothing needs you right now. Decisions and human blockers land here."
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
      props: %{
        fill_width: true,
        background: :surface,
        padding: :space_md,
        gap: 4,
        test_id: "inbox-empty",
        accessibility_id: "inbox-empty"
      },
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

  defp status_banner(title, detail) do
    %{
      type: :column,
      props: %{
        fill_width: true,
        background: :surface_raised,
        padding: :space_sm,
        gap: 4,
        test_id: "inbox-status",
        accessibility_id: "inbox-status"
      },
      children: [
        %{
          type: :text,
          props: %{text: title, text_color: :on_surface, font_weight: "bold", text_size: :sm},
          children: []
        },
        %{type: :text, props: %{text: detail, text_color: :muted, text_size: :xs}, children: []}
      ]
    }
  end

  defp inbox_card(card, assigns) do
    card_id = get(card, "id")
    cached? = get(card, "_cached") == true
    tap_id = if(cached?, do: get(card, "qualified_id") || card_id, else: card_id)
    origin_name = card_origin_name(card) || assigns.host_name
    authoritative? = status_state(assigns.mobile_cards_status) == :joined
    tappable? = is_binary(tap_id) and (cached? or authoritative? or openable_offline?(card))

    %{
      type: :column,
      props: %{
        test_id: "inbox-card",
        accessibility_id: "inbox-card",
        fill_width: true,
        background: :surface,
        padding: :space_md,
        gap: 8
      },
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
              chip(attention_priority_label(card), priority_color(card))
            ]
          },
          attention_reason_line(card),
          since_viewed_line(card),
          card_body(card),
          get(card, "workspace_id") &&
            muted_line(
              card_context_line(origin_name, get(card, "workspace_id"), card, authoritative?)
            ),
          action_button(
            if(cached?, do: "Switch & open", else: action_label(card)),
            {:open_card, tap_id},
            :primary,
            fill_width: true,
            text_color: :on_primary,
            disabled: not tappable?,
            test_id: "inbox-open-card"
          )
        ]
        |> Enum.reject(&is_nil/1)
    }
  end

  defp openable_offline?(card) do
    needs_review_card?(card) or intervention_card?(card) or
      is_binary(get(card, "workspace_id"))
  end

  defp open_card(socket, nil), do: socket

  defp open_card(socket, card) do
    if get(card, "_cached") == true do
      temporary_notice(socket, "Switch to that host from Sessions, then reopen Inbox")
    else
      mark_attention_viewed(card)

      cond do
        needs_review_card?(card) or intervention_card?(card) ->
          socket
          |> remember_card_context(card)
          |> Mob.Socket.push_screen(ReviewDecisionScreen, %{card: card})

        true ->
          open_via_route(socket, card)
      end
    end
  end

  defp open_via_route(socket, card) do
    route = navigation_route(card) || legacy_route(card)
    workspace_id = get(route, "workspace_id") || get(card, "workspace_id")
    session_id = get(route, "session_id") || get(card, "session_id")

    case {get(route, "type"), workspace_id} do
      {"session_detail", wid} when is_binary(wid) ->
        open_session_detail(socket, wid, session_id)

      {_type, wid} when is_binary(wid) ->
        open_session_detail(socket, wid, session_id)

      _ ->
        temporary_notice(socket, "This card has no open target")
    end
  end

  defp open_session_detail(socket, workspace_id, session_id) do
    SessionConfig.put_resume_context(workspace_id,
      session_id: session_id,
      source: :inbox
    )

    params =
      %{workspace_id: workspace_id, session_id: session_id, source: :inbox}
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    Mob.Socket.push_screen(socket, SessionDetailScreen, params)
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

  defp remember_card_context(socket, card) do
    workspace_id = get(card, "workspace_id")

    if is_binary(workspace_id) do
      SessionConfig.put_resume_context(workspace_id,
        session_id: get(card, "session_id"),
        source: :review
      )

      socket
    else
      socket
    end
  end

  defp find_mobile_card(socket, card_id) do
    Map.get(socket.assigns.mobile_cards_by_id, card_id) ||
      Enum.find(socket.assigns.cached_cards, fn card ->
        get(card, "qualified_id") == card_id or get(card, "id") == card_id
      end)
  end

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
        |> Mob.Socket.assign(:cached_cards, SessionConfig.inactive_cached_cards())
        |> assign_pairing()

      {:error, reason} ->
        Mob.Socket.assign(socket, :notice, origin_rejection_notice(reason))
    end
  end

  defp accept_snapshot_origin(descriptor) when is_map(descriptor) do
    case SessionConfig.reconcile_active_origin(descriptor) do
      {:ok, profile} -> {:ok, profile.origin_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp accept_snapshot_origin(_descriptor) do
    case SessionConfig.connection() do
      {:ok, profile} -> {:ok, profile.origin_id}
      :error -> {:error, :unknown_origin}
    end
  end

  defp snapshot_cards(payload) when is_map(payload), do: get(payload, "cards", [])
  defp snapshot_cards(_payload), do: []

  defp snapshot_observed_at(cards) do
    cards
    |> Enum.map(&get(&1, "updated_at"))
    |> Enum.filter(&is_binary/1)
    |> Enum.max(fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)
  end

  defp origin_rejection_notice(:origin_mismatch), do: "Origin mismatch; state was not accepted"
  defp origin_rejection_notice(_reason), do: "Unknown origin; state was not accepted"

  defp maybe_clear_mobile_cards(socket, status) do
    if status_state(status) == :error, do: clear_mobile_cards(socket), else: socket
  end

  defp clear_mobile_cards(socket) do
    socket
    |> Mob.Socket.assign(:mobile_cards_snapshot, nil)
    |> Mob.Socket.assign(:mobile_cards, [])
    |> Mob.Socket.assign(:mobile_cards_by_id, %{})
  end

  defp assign_pairing(socket) do
    case SessionConfig.connection() do
      {:ok, profile} ->
        socket
        |> Mob.Socket.assign(:paired?, true)
        |> Mob.Socket.assign(:host_url, profile.url)
        |> Mob.Socket.assign(:host_name, profile.display_name || host_name(profile.url))
        |> Mob.Socket.assign(:origin_id, profile.origin_id)

      :error ->
        socket
        |> Mob.Socket.assign(:paired?, false)
        |> Mob.Socket.assign(:host_url, nil)
        |> Mob.Socket.assign(:host_name, nil)
        |> Mob.Socket.assign(:origin_id, nil)
    end
  end

  defp initial_status do
    if SessionConfig.pairing() == :error, do: :disconnected, else: :connecting
  end

  defp host_name(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> url
    end
  end

  defp host_name(_), do: "Host"

  defp card_segment(card) do
    resume_state = card |> get("resume", %{}) |> get("state") |> to_string()
    kind = to_string(get(card, "kind") || get(card, "type") || "")
    status = to_string(get(card, "status") || "")

    if unresolved_needs_me?(card) do
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
      kind in ["approval_required", "needs_review", "clarification"] -> :needs_action
      kind == "in_progress" -> :running
      kind == "connection_issue" -> :failed
      kind == "workspace_idle" -> :done
      status in ["resolved", "done"] -> :done
      true -> :needs_action
    end
  end

  defp unresolved_needs_me?(card) do
    attention = get(card, "attention", %{})
    required_decision = get(attention, "required_decision")
    status = to_string(get(card, "status") || "")
    kind = to_string(get(card, "kind") || "")
    type = to_string(get(card, "type") || "")
    terminal? = status in ["resolved", "done", "handled", "dismissed"]

    cond do
      get(card, "sticky") == true ->
        true

      get(attention, "unresolved?") == true ->
        true

      get(attention, "pin") == "needs_me" ->
        true

      Map.has_key?(attention, "unresolved?") ->
        false

      terminal? ->
        false

      is_binary(required_decision) and required_decision != "" ->
        true

      type in ["clarification", "needs_review"] ->
        true

      kind in [
        "clarification_required",
        "direction_required",
        "blocker_required",
        "approval_required"
      ] ->
        true

      true ->
        false
    end
  end

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

  defp card_body(card) do
    case get(card, "body") do
      body when is_binary(body) and body != "" ->
        %{type: :text, props: %{text: body, text_color: :muted, text_size: :sm}, children: []}

      _ ->
        nil
    end
  end

  defp card_context_line(origin_name, workspace_id, card, authoritative?) do
    parts =
      [
        origin_name,
        "Workspace #{short_id(workspace_id)}",
        if(get(card, "_cached") == true, do: "Cached"),
        if(not authoritative? and get(card, "_cached") != true, do: "Refreshing")
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, " · ")
  end

  defp card_origin_name(card) do
    case get(card, "origin") do
      origin when is_map(origin) -> get(origin, "display_name") || get(origin, "id")
      _ -> nil
    end
  end

  defp action_label(card) do
    if needs_review_card?(card) or intervention_card?(card) do
      "Review"
    else
      case get(get(card, "action"), "label") do
        label when is_binary(label) and label != "" -> label
        _ -> "Open"
      end
    end
  end

  defp needs_review_card?(card), do: get(card, "type") in ["needs_review", :needs_review]
  defp intervention_card?(card), do: is_map(get(card, "intervention"))

  defp navigation_route(card) do
    card
    |> get("actions")
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.find_value(fn action -> get(action, "route") end)
  end

  defp legacy_route(card), do: card |> get("action") |> get("route")

  defp card_type_label(type) do
    type
    |> to_string()
    |> String.replace("_", " ")
  end

  defp priority_color(card) do
    case get(get(card, "attention", %{}), "priority") || get(card, "priority") do
      value when value in ["critical", :critical, "high", :high] -> :amber_400
      _ -> :surface_raised
    end
  end

  defp chip(text, background) do
    %{
      type: :text,
      props: %{
        text: to_string(text || ""),
        background: background,
        text_color: :on_surface,
        text_size: :xs,
        padding: :space_xs
      },
      children: []
    }
  end

  defp muted_line(text) when is_binary(text) do
    %{type: :text, props: %{text: text, text_color: :muted, text_size: :sm}, children: []}
  end

  defp muted_line(_), do: nil

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
      if Keyword.has_key?(opts, :fill_width) do
        Map.put(props, :fill_width, Keyword.fetch!(opts, :fill_width))
      else
        props
      end

    props =
      if Keyword.has_key?(opts, :test_id) do
        test_id = Keyword.fetch!(opts, :test_id)

        props
        |> Map.put(:test_id, test_id)
        |> Map.put(:accessibility_id, test_id)
      else
        props
      end

    %{type: :button, props: props, children: []}
  end

  defp notice(nil), do: nil

  defp notice(message) do
    %{
      type: :text,
      props: %{
        text: message,
        background: :surface_raised,
        text_color: :on_surface,
        padding: :space_sm,
        fill_width: true
      },
      children: []
    }
  end

  defp temporary_notice(socket, message) do
    Process.send_after(self(), {:clear_notice, message}, 2_400)
    Mob.Socket.assign(socket, :notice, message)
  end

  defp live_work_hydrating?(assigns) do
    assigns
    |> Map.get(:mobile_cards_snapshot, %{})
    |> get("live_work", %{})
    |> get("status")
    |> Kernel.==("hydrating")
  end

  defp load_failed?(status), do: status_state(status) == :error

  defp load_failure_detail(status) do
    case status do
      {:error, :unauthorized} ->
        "Pairing was revoked. Pair again to reload the inbox."

      {:error, :network_unavailable} ->
        "Network unavailable; the inbox could not refresh."

      {:error, reason} when is_atom(reason) ->
        "Load failed (#{reason}). Pull to retry from Sessions."

      {:error, reason} when is_binary(reason) ->
        "Load failed: #{reason}"

      _ ->
        "The card stream failed. Return to Sessions and reconnect."
    end
  end

  defp status_copy(status) do
    case status_state(status) do
      :connecting ->
        {"Card stream connecting", "Waiting for the authoritative inbox snapshot."}

      :disconnected ->
        {"Card stream offline", "Latest inbox cards may be stale."}

      :error ->
        {"Card stream offline", load_failure_detail(status)}

      _ ->
        nil
    end
  end

  defp status_state(:joined), do: :joined
  defp status_state(:connecting), do: :connecting
  defp status_state(:disconnected), do: :disconnected
  defp status_state({:disconnected, _}), do: :disconnected
  defp status_state({:error, _}), do: :error
  defp status_state(:error), do: :error
  defp status_state(_), do: :connecting

  defp short_id(id) when is_binary(id) and byte_size(id) > 18, do: String.slice(id, 0, 16) <> "…"
  defp short_id(id), do: to_string(id)

  defp get(map, key, default \\ nil)
  defp get(%{} = map, key, default), do: Map.get(map, key) || atom_key(map, key) || default
  defp get(_map, _key, default), do: default

  defp atom_key(map, key) when is_binary(key) do
    try do
      Map.get(map, String.to_existing_atom(key))
    rescue
      ArgumentError -> nil
    end
  end

  defp atom_key(map, key) when is_atom(key), do: Map.get(map, Atom.to_string(key))
  defp atom_key(_map, _key), do: nil
end
