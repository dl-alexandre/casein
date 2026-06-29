defmodule DevIDE.Mobile.Card do
  @moduledoc """
  Pure builders for the mobile card contract.

  The observer owns process state; this module owns only deterministic card
  shaping, ids, dedupe keys, timestamps, and ordering.
  """

  @type card_type :: :needs_review | :in_progress | :connection_issue
  @type priority :: :high | :normal | :low

  @type action :: %{
          required(:label) => String.t(),
          required(:route) => tuple()
        }

  @type t :: %{
          required(:id) => String.t(),
          required(:type) => card_type(),
          required(:priority) => priority(),
          required(:user_id) => String.t(),
          required(:workspace_id) => String.t(),
          required(:workspace_name) => String.t(),
          required(:session_id) => String.t() | nil,
          required(:title) => String.t(),
          required(:body) => String.t() | nil,
          required(:action) => action() | nil,
          required(:secondary_actions) => [map()],
          required(:meta) => map(),
          required(:created_at) => DateTime.t(),
          required(:updated_at) => DateTime.t(),
          required(:expires_at) => DateTime.t() | nil
        }

  @priorities %{high: 0, normal: 1, low: 2}
  @connection_high_reasons [:token_revoked, :join_failed, :invalid_token, :pairing_expired]

  @spec needs_review(map(), DateTime.t()) :: t() | nil
  def needs_review(attrs, now \\ DateTime.utc_now()) when is_map(attrs) do
    review_count = count(attrs[:review_count] || attrs["review_count"])

    if review_count > 0 do
      user_id = require_string!(attrs, :user_id)
      workspace_id = require_string!(attrs, :workspace_id)
      session_id = optional_string(attrs[:session_id] || attrs["session_id"])

      base(
        :needs_review,
        %{
          user_id: user_id,
          workspace_id: workspace_id,
          workspace_name: workspace_name(attrs, workspace_id),
          session_id: session_id,
          priority: :high,
          title: review_title(review_count),
          body: "Review required before work continues",
          action: %{label: "Open", route: {:session_detail, workspace_id, session_id}},
          meta: %{
            review_count: review_count,
            command_id: attrs[:command_id] || attrs["command_id"],
            approval_id: attrs[:approval_id] || attrs["approval_id"],
            actor_id: attrs[:actor_id] || attrs["actor_id"],
            reason: attrs[:reason] || attrs["reason"],
            source: attrs[:source] || attrs["source"],
            target_ref: attrs[:target_ref] || attrs["target_ref"],
            last_activity_at: attrs[:last_activity_at] || attrs["last_activity_at"],
            agent_reasoning:
              attr(attrs, [
                :agent_reasoning,
                "agent_reasoning",
                :reasoning,
                "reasoning",
                :summary,
                "summary"
              ]),
            diff_preview: attr(attrs, [:diff_preview, "diff_preview"]),
            files_changed:
              attr(attrs, [:files_changed, "files_changed", :changed_files, "changed_files"]),
            previous_decisions:
              attr(attrs, [
                :previous_decisions,
                "previous_decisions",
                :decision_history,
                "decision_history"
              ])
          },
          now: now
        }
      )
    end
  end

  @spec in_progress(map(), DateTime.t()) :: t()
  def in_progress(attrs, now \\ DateTime.utc_now()) when is_map(attrs) do
    user_id = require_string!(attrs, :user_id)
    workspace_id = require_string!(attrs, :workspace_id)
    session_id = optional_string(attrs[:session_id] || attrs["session_id"])

    command =
      optional_string(
        attrs[:command] || attrs["command"] || attrs[:command_id] || attrs["command_id"]
      )

    agent_count = count(attrs[:agent_count] || attrs["agent_count"])

    base(
      :in_progress,
      %{
        user_id: user_id,
        workspace_id: workspace_id,
        workspace_name: workspace_name(attrs, workspace_id),
        session_id: session_id,
        priority: :normal,
        title: in_progress_title(command),
        body: in_progress_body(agent_count, attrs[:started_at] || attrs["started_at"]),
        action: %{label: "View", route: {:session_detail, workspace_id, session_id}},
        meta: %{
          run_phase: attrs[:run_phase] || attrs["run_phase"] || "executing",
          agent_count: agent_count,
          last_activity_at: attrs[:last_activity_at] || attrs["last_activity_at"]
        },
        now: now
      }
    )
  end

  @spec connection_issue(map(), DateTime.t()) :: t()
  def connection_issue(attrs, now \\ DateTime.utc_now()) when is_map(attrs) do
    user_id = require_string!(attrs, :user_id)
    workspace_id = require_string!(attrs, :workspace_id)
    reason = reason(attrs[:reason] || attrs["reason"])

    base(
      :connection_issue,
      %{
        user_id: user_id,
        workspace_id: workspace_id,
        workspace_name: workspace_name(attrs, workspace_id),
        session_id: nil,
        priority: connection_priority(reason),
        title: connection_title(reason),
        body: connection_body(reason, attrs[:last_seen_at] || attrs["last_seen_at"]),
        action: connection_action(reason, workspace_id),
        meta: %{
          reason: reason,
          last_seen_at: attrs[:last_seen_at] || attrs["last_seen_at"]
        },
        now: now
      }
    )
  end

  @spec key(t() | map()) :: {String.t(), String.t(), String.t() | nil, card_type()}
  def key(%{user_id: user_id, workspace_id: workspace_id, session_id: session_id, type: type}) do
    {user_id, workspace_id, session_id, type}
  end

  @spec id(card_type(), String.t(), String.t() | nil) :: String.t()
  def id(type, workspace_id, session_id) when is_atom(type) and is_binary(workspace_id) do
    "#{type}:#{workspace_id}:#{session_id || "nil"}"
  end

  @spec merge_update(t() | nil, t(), DateTime.t()) :: t()
  def merge_update(nil, new_card, _now), do: new_card

  def merge_update(%{created_at: created_at}, new_card, now) do
    new_card
    |> Map.put(:created_at, created_at)
    |> Map.put(:updated_at, now)
  end

  @doc "Orders cards for mobile snapshots: priority first, then newest update first."
  @spec order([t()]) :: [t()]
  def order(cards) when is_list(cards) do
    Enum.sort_by(
      cards,
      &{@priorities[&1.priority] || 99, DateTime.to_unix(&1.updated_at, :microsecond) * -1}
    )
  end

  @spec remove_nil_meta(t()) :: t()
  def remove_nil_meta(%{meta: meta} = card) when is_map(meta) do
    meta =
      meta
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{card | meta: meta}
  end

  defp base(type, attrs) do
    workspace_id = attrs.workspace_id
    session_id = attrs.session_id
    now = attrs.now

    %{
      id: id(type, workspace_id, session_id),
      type: type,
      priority: attrs.priority,
      user_id: attrs.user_id,
      workspace_id: workspace_id,
      workspace_name: attrs.workspace_name,
      session_id: session_id,
      title: attrs.title,
      body: attrs.body,
      action: attrs.action,
      secondary_actions: Map.get(attrs, :secondary_actions, []),
      meta: attrs.meta,
      created_at: now,
      updated_at: now,
      expires_at: Map.get(attrs, :expires_at)
    }
    |> remove_nil_meta()
  end

  defp require_string!(attrs, key) do
    value = attrs[key] || attrs[Atom.to_string(key)]

    case optional_string(value) do
      nil -> raise ArgumentError, "expected #{inspect(key)} to be a non-empty string"
      string -> string
    end
  end

  defp workspace_name(attrs, workspace_id) do
    optional_string(attrs[:workspace_name] || attrs["workspace_name"]) || workspace_id
  end

  defp attr(attrs, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(attrs, key) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      string -> string
    end
  end

  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(_value), do: nil

  defp count(value) when is_integer(value) and value > 0, do: value

  defp count(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> 0
    end
  end

  defp count(_value), do: 0

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  defp review_title(1), do: "1 item needs review"
  defp review_title(count), do: "#{count} items need review"

  defp in_progress_title(nil), do: "Work in progress"
  defp in_progress_title(command), do: "Running: " <> command

  defp in_progress_body(0, nil), do: nil

  defp in_progress_body(agent_count, nil),
    do: "#{agent_count} #{plural(agent_count, "agent")} active"

  defp in_progress_body(0, started_at), do: "Started #{format_time(started_at)}"

  defp in_progress_body(agent_count, started_at),
    do:
      "#{agent_count} #{plural(agent_count, "agent")} active - Started #{format_time(started_at)}"

  defp reason(value) when is_atom(value), do: value

  defp reason(value) when is_binary(value) do
    case value do
      "offline" -> :offline
      "token_revoked" -> :token_revoked
      "join_failed" -> :join_failed
      "invalid_token" -> :invalid_token
      "pairing_expired" -> :pairing_expired
      _ -> :unknown
    end
  end

  defp reason(_value), do: :unknown

  defp connection_priority(reason) when reason in @connection_high_reasons, do: :high
  defp connection_priority(_reason), do: :normal

  defp connection_title(:offline), do: "Workspace offline"
  defp connection_title(:token_revoked), do: "Pairing expired"
  defp connection_title(:invalid_token), do: "Pairing expired"
  defp connection_title(:pairing_expired), do: "Pairing expired"
  defp connection_title(:join_failed), do: "Could not join session"
  defp connection_title(_reason), do: "Connection issue"

  defp connection_body(:offline, nil), do: "Workspace may be offline or the network changed"
  defp connection_body(:offline, last_seen_at), do: "Last seen #{format_time(last_seen_at)}"

  defp connection_body(reason, _last_seen_at)
       when reason in [:token_revoked, :invalid_token, :pairing_expired],
       do: "Pairing may have expired or token is invalid"

  defp connection_body(:join_failed, _last_seen_at),
    do: "Pairing may have expired or token is invalid"

  defp connection_body(_reason, _last_seen_at), do: "Try reconnecting to this workspace"

  defp connection_action(reason, workspace_id)
       when reason in [:token_revoked, :invalid_token, :pairing_expired, :join_failed],
       do: %{label: "Pair again", route: {:pair_workspace, workspace_id}}

  defp connection_action(_reason, workspace_id),
    do: %{label: "Retry", route: {:retry_workspace, workspace_id}}

  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(value), do: to_string(value)
end
