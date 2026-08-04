defmodule CaseinMob.ReviewDecisionScreen do
  @moduledoc """
  Lightweight mobile review surface for a `needs_review` observer card.

  The dashboard owns card streaming. This screen owns only the user's decision
  posture: enough context to understand the request, an optional short note,
  and the narrow review actions supported by the server channel.
  """
  use Mob.Screen

  alias CaseinMob.SessionClient

  @max_note_length 280

  def mount(params, _session, socket) do
    card = params[:card] || params["card"] || %{}

    # Subscribe so the real channel reply (accepted/rejected) can replace the
    # optimistic "sent" message.
    SessionClient.watch_mobile_cards(self())

    socket =
      socket
      |> Mob.Socket.assign(:card, card)
      |> Mob.Socket.assign(:note, "")
      |> Mob.Socket.assign(:selected_action, nil)
      |> Mob.Socket.assign(:submitted_action, nil)
      |> Mob.Socket.assign(:action_state, :idle)
      |> Mob.Socket.assign(:authoritative_terminal_state, nil)
      |> Mob.Socket.assign(:trusted_confirmation, nil)
      |> Mob.Socket.assign(:pending_confirmation, nil)
      |> Mob.Socket.assign(:feed_joined?, false)
      |> Mob.Socket.assign(:fresh_card?, false)
      |> Mob.Socket.assign(:authoritative?, false)
      |> Mob.Socket.assign(:intervention_completed, false)
      |> Mob.Socket.assign(:card_expired, false)
      |> Mob.Socket.assign(:message, nil)

    {:ok, socket}
  end

  def handle_info({:change, :note, value}, socket) when is_binary(value) do
    {:noreply, Mob.Socket.assign(socket, :note, normalize_note(value))}
  end

  def handle_info({:tap, {:action, action_id}}, socket) when is_binary(action_id) do
    {:noreply, submit_action(socket, action_id)}
  end

  def handle_info({:tap, {:confirm_action, action_id}}, socket) when is_binary(action_id) do
    {:noreply, confirm_action(socket, action_id)}
  end

  def handle_info({:tap, :cancel_confirmation}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:pending_confirmation, nil)
     |> Mob.Socket.assign(:message, "Action cancelled")}
  end

  def handle_info({:mobile_cards_status, status}, socket) do
    feed_joined? = status_state(status) == :joined
    fresh_card? = feed_joined? and socket.assigns.fresh_card?
    authoritative? = feed_joined? and fresh_card?

    socket =
      socket
      |> Mob.Socket.assign(:feed_joined?, feed_joined?)
      |> Mob.Socket.assign(:fresh_card?, fresh_card?)
      |> Mob.Socket.assign(:authoritative?, authoritative?)
      |> assign_connection_state(status)
      |> maybe_clear_confirmation(authoritative?)
      |> maybe_assign_connection_message(status)

    {:noreply, socket}
  end

  def handle_info({:mobile_cards_snapshot, payload}, socket) do
    card_id = get(socket.assigns.card, "id")

    case Enum.find(get(payload, "cards", []), &(get(&1, "id") == card_id)) do
      card when is_map(card) ->
        if refresh_identity_matches?(socket.assigns.card, card) do
          authoritative? = socket.assigns.feed_joined?

          {:noreply,
           socket
           |> Mob.Socket.assign(:card, card)
           |> Mob.Socket.assign(:fresh_card?, true)
           |> Mob.Socket.assign(:authoritative?, authoritative?)
           |> Mob.Socket.assign(:card_expired, false)
           |> maybe_clear_stale_message()
           |> maybe_restore_idle_state()}
        else
          {:noreply,
           socket
           |> Mob.Socket.assign(:fresh_card?, false)
           |> Mob.Socket.assign(:authoritative?, false)
           |> assign_authoritative_terminal_state(:stale)
           |> Mob.Socket.assign(:card_expired, true)
           |> Mob.Socket.assign(:pending_confirmation, nil)
           |> Mob.Socket.assign(
             :message,
             "This request identity changed. Return to Action Center to refresh."
           )}
        end

      _missing ->
        terminal_state = resolved_or_stale_state(socket)

        socket =
          socket
          |> Mob.Socket.assign(:fresh_card?, false)
          |> Mob.Socket.assign(:authoritative?, false)
          |> assign_authoritative_terminal_state(terminal_state)
          |> Mob.Socket.assign(:pending_confirmation, nil)

        if intervention_action_id?(socket.assigns.submitted_action) or
             socket.assigns.intervention_completed do
          {:noreply,
           socket
           |> Mob.Socket.assign(:card_expired, false)
           |> preserve_intervention_confirmation()}
        else
          {:noreply,
           socket
           |> Mob.Socket.assign(:card_expired, true)
           |> Mob.Socket.assign(:message, "This request expired or was removed.")}
        end
    end
  end

  def handle_info({:card_action_result, card_id, result}, socket) do
    if card_id == get(socket.assigns.card, "id") do
      observe_intervention(socket, result)
      result_state = result_state(socket, result)

      socket =
        socket
        |> Mob.Socket.assign(:message, result_message(socket, result, result_state))
        |> assign_result_state(result_state)
        |> handle_action_result(result)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:tap, :open_pwa}, socket) do
    case pwa_url(socket.assigns.card) do
      url when is_binary(url) and url != "" ->
        observe_escalation(socket.assigns.card, "desktop_required")
        {:noreply, Mob.Socket.push_screen(socket, CaseinMob.WebViewScreen, %{url: url})}

      _ ->
        {:noreply, Mob.Socket.assign(socket, :message, "Full terminal link unavailable")}
    end
  end

  def handle_info({:tap, {:open_evidence, url}}, socket)
      when is_binary(url) and url != "" do
    observe_escalation(socket.assigns.card, "escalated")
    {:noreply, Mob.Socket.push_screen(socket, CaseinMob.WebViewScreen, %{url: url})}
  end

  def handle_info({:tap, :back}, socket) do
    {:noreply, Mob.Socket.pop_screen(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp preserve_intervention_confirmation(
         %{assigns: %{intervention_completed: true, trusted_confirmation: confirmation}} = socket
       )
       when is_binary(confirmation) and confirmation != "",
       do: Mob.Socket.assign(socket, :message, confirmation)

  defp preserve_intervention_confirmation(%{assigns: %{intervention_completed: true}} = socket),
    do: socket

  defp preserve_intervention_confirmation(socket),
    do:
      Mob.Socket.assign(socket, :message, "Request resolved. Waiting for delivery confirmation.")

  def render(assigns) do
    %{
      type: :column,
      props: %{background: :background, fill_width: true, fill_height: true},
      children: [
        header(assigns.card),
        %{
          type: :scroll,
          props: %{fill_width: true, weight: 1},
          children: [
            %{
              type: :column,
              props: %{fill_width: true, padding: :space_md, gap: 10},
              children:
                [
                  summary_card(assigns.card),
                  context_card(assigns.card),
                  intervention_context_card(assigns.card),
                  evidence_card(assigns.card),
                  decision_context_card(assigns.card),
                  state_banner(assigns),
                  note_card(assigns),
                  message(assigns.message),
                  action_bar(assigns),
                  escalation_button(assigns.card)
                ]
                |> Enum.reject(&is_nil/1)
            }
          ]
        }
      ]
    }
  end

  defp header(card) do
    %{
      type: :row,
      props: %{fill_width: true, background: :primary, padding: :space_sm, gap: 8},
      children: [
        %{
          type: :text,
          props: %{
            text: if(intervention?(card), do: "Agent needs you", else: "Review request"),
            text_size: :lg,
            text_color: :on_primary,
            font_weight: "bold",
            weight: 1
          },
          children: []
        },
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
        }
      ]
    }
  end

  defp summary_card(card) do
    %{
      type: :column,
      props: %{fill_width: true, background: :surface, padding: :space_md, gap: 8},
      children:
        [
          %{
            type: :text,
            props: %{
              text: get(card, "title", "Review needed"),
              text_color: :on_surface,
              text_size: :lg,
              font_weight: "bold"
            },
            children: []
          },
          body_text(get(card, "body")),
          badge_line(card)
        ]
        |> Enum.reject(&is_nil/1)
    }
  end

  defp context_card(card) do
    rows =
      [
        {"Workspace", workspace_label(card)},
        {"Run/session", get(card, "session_id")},
        {"Command", command_label(card)},
        {"Review count", review_count_label(card)},
        {"Requested by", meta(card, "actor_id")},
        {"Reason", meta(card, "reason")},
        {"Source", meta(card, "source")},
        {"Target", meta(card, "target_ref")},
        {"Last activity", meta(card, "last_activity_at")},
        {"Approval", meta(card, "approval_id")}
      ]
      |> Enum.reject(fn {_label, value} -> blank?(value) end)
      |> Enum.map(fn {label, value} -> context_row(label, value) end)

    %{
      type: :column,
      props: %{fill_width: true, background: :surface, padding: :space_md, gap: 8},
      children: [
        %{
          type: :text,
          props: %{
            text: "Context",
            text_color: :on_surface,
            font_weight: "bold"
          },
          children: []
        }
        | rows
      ]
    }
  end

  defp decision_context_card(card) do
    sections =
      [
        decision_context_section(
          "Why this needs review",
          first_meta(card, ["agent_reasoning", "reasoning", "summary"])
        ),
        decision_context_section(
          "Recent decisions",
          first_meta(card, ["previous_decisions", "decision_history"])
        )
      ]
      |> Enum.reject(&is_nil/1)

    if sections == [] do
      nil
    else
      %{
        type: :column,
        props: %{fill_width: true, background: :surface, padding: :space_md, gap: 8},
        children: [
          %{
            type: :text,
            props: %{
              text: "Decision context",
              text_color: :on_surface,
              font_weight: "bold"
            },
            children: []
          }
          | sections
        ]
      }
    end
  end

  defp intervention_context_card(card) do
    if intervention?(card) do
      intervention = get(card, "intervention", %{})
      target = get(intervention, "target", %{})
      target_label = if get(target, "role") == "agent", do: "Agent", else: "Unknown"

      availability_label =
        if intervention_contract_valid?(card),
          do: "Revalidated when sent",
          else: "Unknown — refresh required"

      %{
        type: :column,
        props: %{fill_width: true, background: :surface, padding: :space_md, gap: 8},
        children: [
          %{
            type: :text,
            props: %{
              text: "Intervention context",
              text_color: :on_surface,
              font_weight: "bold"
            },
            children: []
          },
          body_text("Target: #{target_label}"),
          body_text("Availability: #{availability_label}"),
          body_text("Terminal context: Not collected on mobile")
        ]
      }
    end
  end

  defp evidence_card(card) do
    evidence = get(card, "evidence", %{})
    changed = get(evidence, "changed_files", %{})
    files = get(changed, "files", []) |> List.wrap() |> Enum.filter(&is_binary/1)
    diff = get(evidence, "diff", %{})
    excerpt = get(diff, "excerpt")
    artifact = get(evidence, "artifact", %{})
    links = get(evidence, "links", []) |> List.wrap() |> Enum.filter(&is_map/1)

    sections =
      [
        evidence_files(files, get(changed, "truncated") == true),
        evidence_diff(excerpt, get(diff, "truncated") == true),
        evidence_artifact(artifact),
        evidence_provenance(evidence),
        evidence_links(links)
      ]
      |> Enum.reject(&is_nil/1)

    if sections == [] do
      nil
    else
      %{
        type: :column,
        props: %{fill_width: true, background: :surface, padding: :space_md, gap: 8},
        children: [
          %{
            type: :text,
            props: %{
              text: "Evidence handoff",
              text_color: :on_surface,
              font_weight: "bold"
            },
            children: []
          }
          | sections
        ]
      }
    end
  end

  defp evidence_files([], _truncated?), do: nil

  defp evidence_files(files, truncated?) do
    suffix = if truncated?, do: "\n…more changed files in PWA", else: ""
    decision_context_section("Changed files", Enum.join(files, "\n") <> suffix)
  end

  defp evidence_diff(excerpt, truncated?) when is_binary(excerpt) and excerpt != "" do
    suffix = if truncated?, do: "\n…bounded excerpt; open full diff in PWA", else: ""
    decision_context_section("Bounded diff excerpt", excerpt <> suffix)
  end

  defp evidence_diff(_excerpt, _truncated?), do: nil

  defp evidence_artifact(artifact) when is_map(artifact) and map_size(artifact) > 0 do
    filename = get(artifact, "filename")
    media_type = get(artifact, "media_type")
    size = get(artifact, "byte_size")

    [filename, media_type, if(is_integer(size), do: "#{size} bytes")]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
    |> then(&decision_context_section("Preview / artifact", &1))
  end

  defp evidence_artifact(_artifact), do: nil

  defp evidence_provenance(evidence) do
    origin = get(evidence, "origin", %{})
    freshness = get(evidence, "freshness", %{})
    origin_name = get(origin, "display_name")
    kind = get(freshness, "kind")
    observed_at = get(freshness, "observed_at")

    [origin_name, kind, observed_at]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
    |> case do
      "" -> nil
      text -> decision_context_section("Origin / freshness", text)
    end
  end

  defp evidence_links([]), do: nil

  defp evidence_links(links) do
    %{
      type: :column,
      props: %{fill_width: true, gap: 8},
      children:
        Enum.flat_map(links, fn link ->
          case {get(link, "label"), get(link, "url")} do
            {label, url}
            when is_binary(label) and label != "" and is_binary(url) and url != "" ->
              [
                %{
                  type: :button,
                  props: %{
                    text: label,
                    background: :surface_raised,
                    text_color: :on_surface,
                    fill_width: true,
                    height: 44.0,
                    on_tap: {self(), {:open_evidence, url}}
                  },
                  children: []
                }
              ]

            _ ->
              []
          end
        end)
    }
  end

  defp decision_context_section(label, value) do
    text = review_context_text(value)

    if blank?(text) do
      nil
    else
      %{
        type: :column,
        props: %{fill_width: true, gap: 3},
        children: [
          %{
            type: :text,
            props: %{text: label, text_color: :muted, text_size: :xs},
            children: []
          },
          %{
            type: :text,
            props: %{text: text, text_color: :on_surface, text_size: :sm},
            children: []
          }
        ]
      }
    end
  end

  defp note_card(%{card_expired: true}), do: nil

  defp note_card(assigns) do
    case reply_action(assigns) do
      spec when is_map(spec) -> note_field(assigns, spec)
      _ -> nil
    end
  end

  defp reply_action(assigns) do
    actions = card_actions(assigns.card)

    Enum.find(actions, &(get(&1, "id") == assigns.selected_action and input_fields(&1) != [])) ||
      case actions do
        [spec] -> if(input_fields(spec) != [], do: spec)
        _ -> nil
      end
  end

  defp note_field(assigns, spec) do
    follow_up? = get(spec, "id") == "follow_up"
    remaining = max_input_length(assigns.card) - String.length(assigns.note)

    %{
      type: :column,
      props: %{fill_width: true, background: :surface, padding: :space_md, gap: 8},
      children: [
        %{
          type: :text,
          props: %{
            text: if(follow_up?, do: "Short follow-up", else: "Note"),
            text_color: :on_surface,
            font_weight: "bold"
          },
          children: []
        },
        %{
          type: :text_field,
          props: %{
            test_id: "needs-me-reply",
            accessibility_id: "needs-me-reply",
            accessibility_label: if(follow_up?, do: "Short follow-up", else: "Short reply"),
            value: assigns.note,
            placeholder:
              if(follow_up?,
                do: "What should the agent do next?",
                else: "Add a short note for request changes"
              ),
            keyboard: :default,
            return_key: :done,
            on_change: {self(), :note}
          },
          children: []
        },
        %{
          type: :text,
          props: %{text: "#{remaining} characters left", text_color: :muted, text_size: :xs},
          children: []
        }
      ]
    }
  end

  # Data-driven: buttons come from the card's server-authored `actions` specs, so
  # the client no longer hardcodes approve/deny/request_changes.
  defp action_bar(assigns) do
    actions = card_actions(assigns.card)
    submitted? = is_binary(assigns.submitted_action)
    invalid_card? = blank?(get(assigns.card, "id"))

    children =
      case {assigns.card_expired, assigns.pending_confirmation, actions} do
        {true, _confirmation, _actions} ->
          [
            body_text(
              "This request is no longer live. Refresh the Action Center before acting again."
            ),
            %{
              type: :button,
              props: %{
                text: "Return to Action Center",
                background: :surface_raised,
                text_color: :on_surface,
                fill_width: true,
                padding: :space_sm,
                height: 44.0,
                on_tap: {self(), :back}
              },
              children: []
            }
          ]

        {false, spec, _actions} when is_map(spec) ->
          confirmation_controls(
            spec,
            assigns.authoritative? and intervention_action_contract_valid?(assigns.card, spec)
          )

        {false, nil, []} ->
          [body_text("No actions available for this card.")]

        {false, nil, specs} ->
          {chips, buttons} = Enum.split_with(specs, &choice_action?/1)

          chip_controls = choice_controls(chips, assigns, submitted?, invalid_card?)

          button_controls =
            Enum.map(buttons, fn spec ->
              disabled? =
                not assigns.authoritative? or submitted? or invalid_card? or
                  not intervention_action_contract_valid?(assigns.card, spec) or
                  action_disabled?(spec, assigns.note, assigns.selected_action) or
                  (assigns.intervention_completed and intervention_action?(spec))

              action_control(spec, disabled?)
            end)
            |> List.flatten()

          chip_controls ++ button_controls
      end

    %{
      type: :column,
      props: %{fill_width: true, gap: 8},
      children: Enum.reject(children, &is_nil/1)
    }
  end

  defp action_chip(spec, disabled?) do
    %{
      type: :button,
      props: %{
        test_id: action_test_id(spec),
        accessibility_id: action_test_id(spec),
        accessibility_label: action_label(spec),
        text: action_label(spec),
        background: :surface_raised,
        text_color: :on_surface,
        fill_width: false,
        padding: :space_sm,
        height: 44.0,
        disabled: disabled?,
        on_tap: {self(), {:action, get(spec, "id")}}
      },
      children: []
    }
  end

  defp choice_controls([], _assigns, _submitted?, _invalid_card?), do: []

  defp choice_controls(chips, assigns, submitted?, invalid_card?) do
    controls =
      Enum.map(chips, fn spec ->
        disabled? =
          not assigns.authoritative? or submitted? or invalid_card? or
            not intervention_action_contract_valid?(assigns.card, spec) or
            (assigns.intervention_completed and intervention_action?(spec))

        action_chip(spec, disabled?)
      end)

    vertical? = length(chips) > 2 or Enum.any?(chips, &(String.length(action_label(&1)) > 18))

    [
      %{
        type: if(vertical?, do: :column, else: :row),
        props: %{
          test_id: "needs-me-choice-group",
          accessibility_id: "needs-me-choice-group",
          accessibility_label: "Available choices",
          fill_width: true,
          gap: 8
        },
        children:
          if(vertical?,
            do: Enum.map(controls, &put_in(&1, [:props, :fill_width], true)),
            else: controls
          )
      }
    ]
  end

  defp confirmation_controls(spec, authoritative?) do
    prompt =
      case get(spec, "confirmation") do
        value when is_binary(value) and value != "" -> value
        _ -> "Confirm #{String.downcase(action_label(spec))}?"
      end

    [
      body_text(prompt),
      %{
        type: :button,
        props: %{
          test_id: "needs-me-confirm-#{get(spec, "id")}",
          accessibility_id: "needs-me-confirm-#{get(spec, "id")}",
          accessibility_label: "Confirm #{action_label(spec)}",
          text: "Confirm #{action_label(spec)}",
          background: style_background(get(spec, "style")),
          text_color: style_text_color(get(spec, "style")),
          fill_width: true,
          padding: :space_sm,
          height: 44.0,
          disabled: not authoritative?,
          on_tap: {self(), {:confirm_action, get(spec, "id")}}
        },
        children: []
      },
      %{
        type: :button,
        props: %{
          test_id: "needs-me-cancel-confirmation",
          accessibility_id: "needs-me-cancel-confirmation",
          accessibility_label: "Cancel confirmation",
          text: "Cancel",
          background: :surface_raised,
          text_color: :on_surface,
          fill_width: true,
          padding: :space_sm,
          height: 44.0,
          on_tap: {self(), :cancel_confirmation}
        },
        children: []
      }
    ]
  end

  defp action_button(spec, disabled?) do
    %{
      type: :button,
      props: %{
        test_id: action_test_id(spec),
        accessibility_id: action_test_id(spec),
        accessibility_label: action_label(spec),
        text: action_label(spec),
        background: style_background(get(spec, "style")),
        text_color: style_text_color(get(spec, "style")),
        fill_width: true,
        padding: :space_sm,
        height: 44.0,
        disabled: disabled?,
        on_tap: {self(), {:action, get(spec, "id")}}
      },
      children: []
    }
  end

  defp action_control(spec, disabled?) do
    [
      case get(spec, "description") do
        description when is_binary(description) and description != "" ->
          body_text(description)

        _ ->
          nil
      end,
      action_button(spec, disabled?)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp submit_action(%{assigns: %{card_expired: true}} = socket, _action_id) do
    Mob.Socket.assign(socket, :message, "Refresh the Action Center before acting again.")
  end

  defp submit_action(%{assigns: %{authoritative?: false}} = socket, _action_id) do
    Mob.Socket.assign(socket, :message, "Reconnect and refresh before acting.")
  end

  defp submit_action(socket, action_id) do
    case find_action(socket.assigns.card, action_id) do
      nil ->
        Mob.Socket.assign(socket, :message, "Action unavailable")

      spec ->
        cond do
          not intervention_action_contract_valid?(socket.assigns.card, spec) ->
            Mob.Socket.assign(socket, :message, "Action unavailable. Refresh required.")

          requires_note?(spec) and String.trim(socket.assigns.note) == "" ->
            socket
            |> Mob.Socket.assign(:selected_action, action_id)
            |> Mob.Socket.assign(:message, "Add a short note first")

          true ->
            maybe_confirm(socket, spec)
        end
    end
  end

  defp maybe_confirm(socket, spec) do
    if get(spec, "destructive?") == true do
      socket
      |> Mob.Socket.assign(:pending_confirmation, spec)
      |> Mob.Socket.assign(:message, nil)
    else
      submit(socket, spec)
    end
  end

  defp confirm_action(%{assigns: %{authoritative?: false}} = socket, _action_id) do
    socket
    |> Mob.Socket.assign(:pending_confirmation, nil)
    |> Mob.Socket.assign(:message, "Reconnect and refresh before acting.")
  end

  defp confirm_action(socket, action_id) do
    case socket.assigns.pending_confirmation do
      spec when is_map(spec) ->
        cond do
          not intervention_action_contract_valid?(socket.assigns.card, spec) ->
            socket
            |> Mob.Socket.assign(:pending_confirmation, nil)
            |> Mob.Socket.assign(:message, "Action unavailable. Refresh required.")

          get(spec, "id") == action_id ->
            socket
            |> Mob.Socket.assign(:pending_confirmation, nil)
            |> submit(spec)

          true ->
            socket
            |> Mob.Socket.assign(:pending_confirmation, nil)
            |> Mob.Socket.assign(:message, "Action unavailable")
        end

      _ ->
        Mob.Socket.assign(socket, :message, "Action unavailable")
    end
  end

  defp maybe_clear_confirmation(socket, true), do: socket

  defp maybe_clear_confirmation(socket, false) do
    Mob.Socket.assign(socket, :pending_confirmation, nil)
  end

  defp maybe_assign_connection_message(socket, status) do
    if status_state(status) in [:disconnected, :error] do
      Mob.Socket.assign(socket, :message, "Connection lost. Reconnect and refresh before acting.")
    else
      socket
    end
  end

  defp assign_connection_state(socket, status) do
    if status_state(status) in [:disconnected, :error] do
      Mob.Socket.assign(socket, :action_state, :offline)
    else
      socket
    end
  end

  defp maybe_restore_idle_state(
         %{
           assigns: %{action_state: state, authoritative?: true}
         } = socket
       )
       when state in [:offline, :stale] do
    socket
    |> Mob.Socket.assign(:action_state, :idle)
    |> Mob.Socket.assign(:authoritative_terminal_state, nil)
  end

  defp maybe_restore_idle_state(socket), do: socket

  defp maybe_clear_stale_message(%{assigns: %{action_state: :stale}} = socket),
    do: Mob.Socket.assign(socket, :message, nil)

  defp maybe_clear_stale_message(socket), do: socket

  defp resolved_or_stale_state(socket) do
    if intervention_action_id?(socket.assigns.submitted_action) or
         socket.assigns.intervention_completed or socket.assigns.action_state == :accepted,
       do: :resolved,
       else: :stale
  end

  # Connection status is presentation state; a late success must not make an
  # offline screen appear actionable or erase an authoritative terminal state.
  defp result_state(%{assigns: %{action_state: :offline}}, _result), do: :offline

  defp result_state(
         %{assigns: %{authoritative_terminal_state: state}},
         _result
       )
       when state in [:resolved, :stale],
       do: state

  defp result_state(_socket, {:ok, _result}), do: :accepted

  defp result_state(_socket, {:error, reason})
       when reason in [
              "card_not_found",
              :card_not_found,
              "action_revision_stale",
              :action_revision_stale,
              "intervention_target_missing",
              :intervention_target_missing,
              "intervention_target_stale",
              :intervention_target_stale,
              "intervention_target_role_mismatch",
              :intervention_target_role_mismatch,
              "intervention_unavailable",
              :intervention_unavailable,
              "card_already_intervened",
              :card_already_intervened
            ],
       do: :stale

  defp result_state(_socket, {:error, _reason}), do: :idle

  defp result_message(socket, _result, :offline), do: socket.assigns.message

  defp result_message(
         %{assigns: %{authoritative_terminal_state: :stale}} = socket,
         {:ok, _result},
         :stale
       ),
       do: socket.assigns.message

  defp result_message(
         %{assigns: %{authoritative_terminal_state: :resolved}} = socket,
         {:error, _reason},
         :resolved
       ),
       do: socket.assigns.message

  defp result_message(_socket, result, _state), do: result_message(result)

  defp assign_result_state(socket, state) when state in [:resolved, :stale],
    do: assign_authoritative_terminal_state(socket, state)

  defp assign_result_state(socket, state), do: Mob.Socket.assign(socket, :action_state, state)

  defp assign_authoritative_terminal_state(socket, state) when state in [:resolved, :stale] do
    socket
    |> Mob.Socket.assign(:action_state, state)
    |> Mob.Socket.assign(:authoritative_terminal_state, state)
  end

  defp refresh_identity_matches?(current, incoming) do
    get(current, "id") == get(incoming, "id") and
      get(current, "session_id") == get(incoming, "session_id") and
      get(get(current, "origin", %{}), "id") == get(get(incoming, "origin", %{}), "id") and
      action_revisions(current) != [] and action_revisions(current) == action_revisions(incoming)
  end

  defp action_revisions(card) do
    card
    |> card_actions()
    |> Enum.map(&get(&1, "revision"))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp status_state({state, _reason}) when state in [:joined, :connecting, :disconnected, :error],
    do: state

  defp status_state(state) when state in [:joined, :connecting, :disconnected, :error], do: state
  defp status_state(_status), do: :connecting

  defp submit(socket, spec) do
    card_id = get(socket.assigns.card, "id")
    action_id = get(spec, "id")

    if is_binary(card_id) and card_id != "" and is_binary(action_id) do
      origin_id = socket.assigns.card |> get("origin", %{}) |> get("id")

      SessionClient.card_action(
        card_id,
        action_id,
        action_payload(spec, socket.assigns.note),
        origin_id
      )

      socket
      |> Mob.Socket.assign(:selected_action, action_id)
      |> Mob.Socket.assign(:submitted_action, action_id)
      |> Mob.Socket.assign(:action_state, :pending)
      |> Mob.Socket.assign(:message, "#{action_label(spec)} sent")
    else
      Mob.Socket.assign(socket, :message, "Review card unavailable")
    end
  end

  defp action_payload(spec, note) do
    value = String.trim(note)

    payload =
      input_fields(spec)
      |> Enum.reduce(%{}, fn field, acc ->
        case get(field, "name") do
          name when name in ["note", "message"] and value != "" -> Map.put(acc, name, value)
          _ -> acc
        end
      end)

    case get(spec, "revision") do
      revision when is_binary(revision) and revision != "" ->
        Map.put(payload, "revision", revision)

      _ ->
        payload
    end
  end

  defp card_actions(card) do
    card |> get("actions") |> List.wrap() |> Enum.filter(&is_map/1)
  end

  defp find_action(card, action_id) do
    Enum.find(card_actions(card), &(get(&1, "id") == action_id))
  end

  defp input_fields(spec) do
    spec |> get("input") |> List.wrap() |> Enum.filter(&is_map/1)
  end

  defp requires_note?(spec) do
    Enum.any?(input_fields(spec), &(get(&1, "required") in [true, "true"]))
  end

  defp action_disabled?(spec, note, selected_action) do
    requires_note?(spec) and get(spec, "id") == selected_action and String.trim(note) == ""
  end

  defp action_label(spec) do
    case get(spec, "label") do
      label when is_binary(label) and label != "" -> label
      _ -> String.capitalize(to_string(get(spec, "id") || "action"))
    end
  end

  defp choice_action?(spec) do
    get(spec, "style") == "chip" or
      (is_binary(get(spec, "id")) and String.starts_with?(get(spec, "id"), "choose_"))
  end

  defp action_test_id(spec), do: "needs-me-action-#{get(spec, "id") || "unknown"}"

  defp max_input_length(card) do
    card
    |> card_actions()
    |> Enum.flat_map(&input_fields/1)
    |> Enum.map(&get(&1, "max_length"))
    |> Enum.filter(&is_integer/1)
    |> Enum.min(fn -> @max_note_length end)
  end

  defp intervention?(card) do
    is_map(get(card, "intervention")) or Enum.any?(card_actions(card), &intervention_action?/1)
  end

  defp intervention_contract_valid?(card) do
    if intervention?(card) do
      intervention = get(card, "intervention", %{})

      get(get(intervention, "target", %{}), "role") == "agent" and
        get(intervention, "availability") == "revalidated_on_submit"
    else
      true
    end
  end

  defp intervention_action_contract_valid?(card, spec) do
    not intervention_action?(spec) or intervention_contract_valid?(card)
  end

  defp escalation_button(card) do
    if pwa_url(card) do
      %{
        type: :button,
        props: %{
          text: "Open full terminal in PWA",
          background: :surface_raised,
          text_color: :on_surface,
          height: 44.0,
          on_tap: {self(), :open_pwa}
        },
        children: []
      }
    end
  end

  defp pwa_url(card) do
    get(get(card, "intervention", %{}), "pwa_url") || get(card, "pwa_url")
  end

  defp handle_action_result(
         %{assigns: %{authoritative_terminal_state: :stale}} = socket,
         {:ok, _result}
       ) do
    Mob.Socket.assign(socket, :submitted_action, nil)
  end

  defp handle_action_result(socket, {:ok, result}) do
    if intervention_action_id?(socket.assigns.submitted_action) do
      socket
      |> Mob.Socket.assign(:submitted_action, nil)
      |> Mob.Socket.assign(:intervention_completed, true)
      |> Mob.Socket.assign(:trusted_confirmation, result_message({:ok, result}))
    else
      socket
    end
  end

  defp handle_action_result(
         %{assigns: %{authoritative_terminal_state: :resolved}} = socket,
         {:error, _reason}
       ) do
    Mob.Socket.assign(socket, :submitted_action, nil)
  end

  defp handle_action_result(socket, {:error, reason}) do
    socket
    |> Mob.Socket.assign(:submitted_action, nil)
    |> maybe_expire_card(reason)
  end

  defp maybe_expire_card(socket, reason)
       when reason in [
              "card_not_found",
              :card_not_found,
              "action_revision_stale",
              :action_revision_stale,
              "intervention_target_missing",
              :intervention_target_missing,
              "intervention_target_stale",
              :intervention_target_stale,
              "intervention_target_role_mismatch",
              :intervention_target_role_mismatch,
              "intervention_unavailable",
              :intervention_unavailable,
              "card_already_intervened",
              :card_already_intervened
            ],
       do: Mob.Socket.assign(socket, :card_expired, true)

  defp maybe_expire_card(socket, _reason), do: socket

  defp intervention_action?(spec), do: intervention_action_id?(get(spec, "id"))

  defp intervention_action_id?(action_id) do
    action_id in ["follow_up", "continue_task", "address_review", "summarize_blocker"] or
      (is_binary(action_id) and String.starts_with?(action_id, "choose_"))
  end

  defp observe_intervention(socket, result) do
    if socket.assigns.submitted_action in [
         "follow_up",
         "continue_task",
         "address_review",
         "summarize_blocker"
       ] or
         (is_binary(socket.assigns.submitted_action) and
            String.starts_with?(socket.assigns.submitted_action, "choose_")) do
      SessionClient.mobile_observation(%{
        "event" => "intervention",
        "outcome" => if(match?({:ok, _}, result), do: "succeeded", else: "failed"),
        "workspace_id" => get(socket.assigns.card, "workspace_id"),
        "card_id" => get(socket.assigns.card, "id")
      })
    end
  end

  defp observe_escalation(card, outcome) do
    SessionClient.mobile_observation(%{
      "event" => "attention_action",
      "outcome" => outcome,
      "action_kind" => "pwa",
      "workspace_id" => get(card, "workspace_id"),
      "card_id" => get(card, "id")
    })
  end

  defp style_background("primary"), do: :primary
  defp style_background(_style), do: :surface_raised

  defp style_text_color("primary"), do: :on_primary
  defp style_text_color(_style), do: :on_surface

  defp result_message({:ok, result}) when is_map(result) do
    case get(result, "result", %{}) |> get("confirmation") do
      confirmation when is_binary(confirmation) and confirmation != "" ->
        confirmation <> " Waiting for an authoritative update."

      _ ->
        "Action accepted"
    end
  end

  defp result_message({:ok, _result}), do: "Action accepted"

  defp result_message({:error, reason}) when reason in ["card_not_found", :card_not_found],
    do: "This request expired or was removed. Refresh the Action Center to continue."

  defp result_message({:error, reason}), do: "Action failed: #{humanize_reason(reason)}"

  defp humanize_reason(reason) when is_binary(reason), do: String.replace(reason, "_", " ")
  defp humanize_reason(reason), do: inspect(reason)

  defp context_row(label, value) do
    %{
      type: :column,
      props: %{fill_width: true, gap: 2},
      children: [
        %{type: :text, props: %{text: label, text_color: :muted, text_size: :xs}, children: []},
        %{
          type: :text,
          props: %{text: to_string(value), text_color: :on_surface, text_size: :sm},
          children: []
        }
      ]
    }
  end

  defp badge_line(card) do
    %{
      type: :row,
      props: %{fill_width: true, gap: 8},
      children: [
        chip("needs review", :amber_400),
        chip(get(card, "priority", "high"), :surface_raised)
      ]
    }
  end

  defp chip(text, color) do
    %{
      type: :text,
      props: %{
        text: to_string(text),
        text_size: :xs,
        text_color: :on_surface,
        background: color,
        padding_left: :space_sm,
        padding_right: :space_sm,
        padding_top: 6,
        padding_bottom: 6
      },
      children: []
    }
  end

  defp body_text(value) when is_binary(value) and value != "" do
    %{type: :text, props: %{text: value, text_color: :muted, text_size: :sm}, children: []}
  end

  defp body_text(_value), do: nil

  defp message(nil), do: nil

  defp message(value) do
    %{
      type: :text,
      props: %{
        text: value,
        fill_width: true,
        background: :surface_raised,
        text_color: :on_surface,
        text_size: :sm,
        padding: :space_sm
      },
      children: []
    }
  end

  defp state_banner(%{action_state: :idle}), do: nil

  defp state_banner(assigns) do
    {label, detail, color} =
      case assigns.action_state do
        :pending ->
          {"Sending", "Waiting for the server to accept this action.", :amber_400}

        :accepted ->
          {"Accepted", "Waiting for an authoritative card update.", :primary}

        :offline ->
          {"Offline", "Actions are read-only until reconnection and refresh.", :surface_raised}

        :stale ->
          {"Stale", "This request changed. Return to Action Center to refresh.", :surface_raised}

        :resolved ->
          {"Resolved", "This request is no longer awaiting action.", :primary}
      end

    %{
      type: :column,
      props: %{
        fill_width: true,
        background: color,
        padding: :space_sm,
        gap: 3
      },
      children: [
        %{
          type: :text,
          props: %{
            test_id: "needs-me-state-#{assigns.action_state}",
            accessibility_id: "needs-me-state-#{assigns.action_state}",
            accessibility_label: "Request state: #{label}",
            text: label,
            text_color: :on_surface,
            font_weight: "bold"
          },
          children: []
        },
        body_text(detail)
      ]
    }
  end

  defp workspace_label(card) do
    get(card, "workspace_name") || get(card, "workspace_id")
  end

  defp command_label(card) do
    meta(card, "command") || meta(card, "command_id") || get(card, "command")
  end

  defp review_count_label(card) do
    case meta(card, "review_count") do
      nil -> nil
      value -> to_string(value)
    end
  end

  defp meta(card, key) do
    card
    |> get("meta", %{})
    |> get(key)
  end

  defp first_meta(card, keys) do
    Enum.find_value(keys, fn key ->
      case meta(card, key) do
        value when value in [nil, ""] -> nil
        value -> value
      end
    end)
  end

  defp review_context_text(nil), do: ""

  defp review_context_text(value) when is_binary(value), do: String.trim(value)

  defp review_context_text(value) when is_atom(value), do: Atom.to_string(value)

  defp review_context_text(value)
       when is_integer(value) or is_float(value) or is_boolean(value) do
    to_string(value)
  end

  defp review_context_text(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp review_context_text(value) when is_list(value) do
    value
    |> Enum.map(&review_context_text/1)
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp review_context_text(%{} = value) do
    value
    |> Enum.map(fn {key, nested} ->
      text = review_context_text(nested)

      if blank?(text) do
        nil
      else
        "#{human_key(key)}: #{text}"
      end
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp review_context_text(value), do: to_string(value)

  defp human_key(key) do
    key
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp get(map, key, default \\ nil)
  defp get(%{} = map, key, default), do: Map.get(map, key) || atom_key(map, key) || default
  defp get(_map, _key, default), do: default

  defp atom_key(map, key) when is_binary(key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp normalize_note(value) do
    value
    |> String.slice(0, @max_note_length)
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(value), do: is_nil(value)
end
