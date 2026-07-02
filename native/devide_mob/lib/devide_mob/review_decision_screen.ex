defmodule DevideMob.ReviewDecisionScreen do
  @moduledoc """
  Lightweight mobile review surface for a `needs_review` observer card.

  The dashboard owns card streaming. This screen owns only the user's decision
  posture: enough context to understand the request, an optional short note,
  and the narrow review actions supported by the server channel.
  """
  use Mob.Screen

  alias DevideMob.SessionClient

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
      {:noreply, Mob.Socket.assign(socket, :message, result_message(result))}
    else
      {:noreply, socket}
    end
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
        header(),
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
                  decision_context_card(assigns.card),
                  note_card(assigns),
                  message(assigns.message),
                  action_bar(assigns)
                ]
                |> Enum.reject(&is_nil/1)
            }
          ]
        }
      ]
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
            padding: :space_sm,
            height: 44.0,
            on_tap: {self(), :back}
          },
          children: []
        },
        %{
          type: :text,
          props: %{
            text: "Review request",
            text_size: :lg,
            text_color: :on_primary,
            font_weight: "bold",
            weight: 1
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
        decision_context_section("Diff preview", meta(card, "diff_preview")),
        decision_context_section(
          "Files changed",
          first_meta(card, ["files_changed", "changed_files"])
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

  defp note_card(assigns) do
    if any_note_input?(card_actions(assigns.card)), do: note_field(assigns)
  end

  defp any_note_input?(actions) do
    Enum.any?(actions, &(input_fields(&1) != []))
  end

  defp note_field(assigns) do
    remaining = @max_note_length - String.length(assigns.note)

    %{
      type: :column,
      props: %{fill_width: true, background: :surface, padding: :space_md, gap: 8},
      children: [
        %{
          type: :text,
          props: %{text: "Note", text_color: :on_surface, font_weight: "bold"},
          children: []
        },
        %{
          type: :text_field,
          props: %{
            value: assigns.note,
            placeholder: "Add a short note for request changes",
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
      case actions do
        [] ->
          [body_text("No actions available for this card.")]

        specs ->
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
        weight: 1,
        padding: :space_sm,
        height: 44.0,
        disabled: disabled?,
        on_tap: {self(), {:action, get(spec, "id")}}
      },
      children: []
    }
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
      SessionClient.card_action(card_id, action_id, action_payload(spec, socket.assigns.note))

      socket
      |> Mob.Socket.assign(:submitted_action, action_id)
      |> Mob.Socket.assign(:message, "#{action_label(spec)} sent")
    else
      Mob.Socket.assign(socket, :message, "Review card unavailable")
    end
  end

  defp action_payload(spec, note) do
    if input_fields(spec) != [] and String.trim(note) != "" do
      %{"note" => String.trim(note)}
    else
      %{}
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

  defp action_disabled?(spec, note) do
    requires_note?(spec) and String.trim(note) == ""
  end

  defp action_label(spec) do
    case get(spec, "label") do
      label when is_binary(label) and label != "" -> label
      _ -> String.capitalize(to_string(get(spec, "id") || "action"))
    end
  end

  defp style_background("primary"), do: :primary
  defp style_background(_style), do: :surface_raised

  defp style_text_color("primary"), do: :on_primary
  defp style_text_color(_style), do: :on_surface

  defp result_message({:ok, _result}), do: "Action accepted"
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
