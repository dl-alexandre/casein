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
      |> Mob.Socket.assign(:submitted_action, nil)
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

  def handle_info({:card_action_result, card_id, result}, socket) do
    if card_id == get(socket.assigns.card, "id") do
      observe_intervention(socket, result)

      socket =
        socket
        |> Mob.Socket.assign(:message, result_message(result))
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
                  recent_output_card(assigns.card),
                  evidence_card(assigns.card),
                  decision_context_card(assigns.card),
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

  defp recent_output_card(card) do
    case card |> get("intervention", %{}) |> get("recent_output") do
      output when is_binary(output) and output != "" ->
        %{
          type: :column,
          props: %{fill_width: true, background: :surface, padding: :space_md, gap: 8},
          children: [
            %{
              type: :text,
              props: %{
                text: "Recent agent output",
                text_color: :on_surface,
                font_weight: "bold"
              },
              children: []
            },
            %{
              type: :text,
              props: %{text: output, text_color: :on_surface, text_size: :sm},
              children: []
            },
            %{
              type: :text,
              props: %{
                text: "Live excerpt · target role: agent",
                text_color: :muted,
                text_size: :xs
              },
              children: []
            }
          ]
        }

      _ ->
        nil
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
    if any_note_input?(card_actions(assigns.card)), do: note_field(assigns)
  end

  defp any_note_input?(actions) do
    Enum.any?(actions, &(input_fields(&1) != []))
  end

  defp note_field(assigns) do
    follow_up? = follow_up_action?(assigns.card)
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
      case {assigns.card_expired, actions} do
        {true, _actions} ->
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

        {false, []} ->
          [body_text("No actions available for this card.")]

        {false, specs} ->
          Enum.map(specs, fn spec ->
            disabled? = submitted? or invalid_card? or action_disabled?(spec, assigns.note)
            action_button(spec, disabled?)
          end)
      end

    %{
      type: :column,
      props: %{fill_width: true, gap: 8},
      children: Enum.reject(children, &is_nil/1)
    }
  end

  defp action_button(spec, disabled?) do
    %{
      type: :button,
      props: %{
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

  defp submit_action(%{assigns: %{card_expired: true}} = socket, _action_id) do
    Mob.Socket.assign(socket, :message, "Refresh the Action Center before acting again.")
  end

  defp submit_action(socket, action_id) do
    case find_action(socket.assigns.card, action_id) do
      nil ->
        Mob.Socket.assign(socket, :message, "Action unavailable")

      spec ->
        if requires_note?(spec) and String.trim(socket.assigns.note) == "" do
          Mob.Socket.assign(socket, :message, "Add a short note first")
        else
          submit(socket, spec)
        end
    end
  end

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
      |> Mob.Socket.assign(:submitted_action, action_id)
      |> Mob.Socket.assign(:message, "#{action_label(spec)} sent")
    else
      Mob.Socket.assign(socket, :message, "Review card unavailable")
    end
  end

  defp action_payload(spec, note) do
    value = String.trim(note)

    input_fields(spec)
    |> Enum.reduce(%{}, fn field, acc ->
      case get(field, "name") do
        name when name in ["note", "message"] and value != "" -> Map.put(acc, name, value)
        _ -> acc
      end
    end)
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

  defp action_disabled?(spec, note) do
    requires_note?(spec) and String.trim(note) == ""
  end

  defp action_label(spec) do
    case get(spec, "label") do
      label when is_binary(label) and label != "" -> label
      _ -> String.capitalize(to_string(get(spec, "id") || "action"))
    end
  end

  defp follow_up_action?(card) do
    Enum.any?(card_actions(card), &(get(&1, "id") == "follow_up"))
  end

  defp max_input_length(card) do
    card
    |> card_actions()
    |> Enum.flat_map(&input_fields/1)
    |> Enum.map(&get(&1, "max_length"))
    |> Enum.filter(&is_integer/1)
    |> Enum.min(fn -> @max_note_length end)
  end

  defp intervention?(card), do: is_map(get(card, "intervention"))

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

  defp handle_action_result(socket, {:error, reason}) do
    socket
    |> Mob.Socket.assign(:submitted_action, nil)
    |> maybe_expire_card(reason)
  end

  defp handle_action_result(socket, _result), do: socket

  defp maybe_expire_card(socket, reason) when reason in ["card_not_found", :card_not_found],
    do: Mob.Socket.assign(socket, :card_expired, true)

  defp maybe_expire_card(socket, _reason), do: socket

  defp observe_intervention(socket, result) do
    if socket.assigns.submitted_action == "follow_up" do
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
