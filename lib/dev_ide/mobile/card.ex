defmodule Casein.Mobile.Card do
  @moduledoc """
  Pure builders for the mobile card contract.

  The observer owns process state; this module owns only deterministic card
  shaping, ids, dedupe keys, timestamps, and ordering.
  """

  @type card_type :: :needs_review | :in_progress | :connection_issue | :workspace_idle
  @type priority :: :high | :normal | :low

  @type action :: %{
          required(:label) => String.t(),
          required(:route) => tuple()
        }

  @type resource :: %{
          required(:type) => String.t(),
          required(:id) => String.t(),
          required(:label) => String.t()
        }

  @typedoc "A declarative input field on an action spec (v1 supports :text)."
  @type input_field :: %{
          required(:name) => atom(),
          required(:type) => :text,
          required(:required) => boolean(),
          optional(:max_length) => pos_integer()
        }

  @typedoc """
  A server-authored, client-renderable action the mobile app may submit for a
  card. The client renders these and submits the `id` plus validated params; it
  never invents actions.
  """
  @type action_spec :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          required(:style) => String.t(),
          required(:destructive?) => boolean(),
          required(:confirmation) => String.t() | nil,
          required(:input) => [input_field()],
          # Navigation actions carry a client route and are dispatched without any
          # runtime mutation (the server records the intent for audit only).
          optional(:route) => tuple()
        }

  @type t :: %{
          required(:id) => String.t(),
          required(:type) => card_type(),
          required(:source) => String.t(),
          required(:kind) => String.t(),
          required(:status) => String.t(),
          required(:priority) => priority(),
          required(:user_id) => String.t(),
          required(:workspace_id) => String.t(),
          required(:workspace_name) => String.t(),
          required(:resource) => resource(),
          required(:session_id) => String.t() | nil,
          required(:title) => String.t(),
          required(:body) => String.t() | nil,
          required(:action) => action() | nil,
          required(:secondary_actions) => [map()],
          required(:actions) => [action_spec()],
          required(:context) => map(),
          required(:meta) => map(),
          required(:created_at) => DateTime.t(),
          required(:updated_at) => DateTime.t(),
          required(:expires_at) => DateTime.t() | nil
        }

  @priorities %{high: 0, normal: 1, low: 2}
  @connection_high_reasons [:token_revoked, :join_failed, :invalid_token, :pairing_expired]
  @review_note_max_length 280

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
          status: "open",
          actions: review_action_specs(),
          context: %{
            session_id: session_id,
            command_id: attrs[:command_id] || attrs["command_id"],
            files_changed:
              attr(attrs, [:files_changed, "files_changed", :changed_files, "changed_files"]),
            diff_preview: attr(attrs, [:diff_preview, "diff_preview"])
          },
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
        status: "running",
        context: %{session_id: session_id},
        actions: [
          navigation_action_spec("open", "View", {:session_detail, workspace_id, session_id})
        ],
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
        actions: [connection_action_spec(reason, workspace_id)],
        meta: %{
          reason: reason,
          last_seen_at: attrs[:last_seen_at] || attrs["last_seen_at"]
        },
        now: now
      }
    )
  end

  @doc """
  First non-review "control" card: a workspace with no active work, offering a
  route-only "resume" action. Requires a `session_id` to resume; returns `nil`
  without one. No runtime mutation is implied — the action only navigates.
  """
  @spec workspace_idle(map(), DateTime.t()) :: t() | nil
  def workspace_idle(attrs, now \\ DateTime.utc_now()) when is_map(attrs) do
    user_id = require_string!(attrs, :user_id)
    workspace_id = require_string!(attrs, :workspace_id)
    # Deliberately avoid `optional_string/1` here: it coerces the `nil` atom to
    # the string "nil", which would defeat the "no session to resume" guard.
    session_id = binary_session(attrs[:session_id] || attrs["session_id"])
    last_activity_at = attrs[:last_activity_at] || attrs["last_activity_at"]

    if session_id do
      base(
        :workspace_idle,
        %{
          user_id: user_id,
          workspace_id: workspace_id,
          workspace_name: workspace_name(attrs, workspace_id),
          session_id: session_id,
          priority: :low,
          status: "idle",
          actions: [resume_action_spec(workspace_id, session_id)],
          context: %{session_id: session_id, last_activity_at: last_activity_at},
          title: "Workspace idle",
          body: "No active work - resume the latest session",
          action: %{label: "Resume", route: {:session_detail, workspace_id, session_id}},
          meta: %{last_activity_at: last_activity_at},
          now: now
        }
      )
    end
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

  @doc """
  The action specs offered on a `needs_review` card. Server-authored and stable;
  the client renders these and submits the chosen `id` plus validated params.
  """
  @spec review_action_specs() :: [action_spec()]
  def review_action_specs do
    [
      %{
        id: "approve",
        label: "Approve",
        style: "primary",
        destructive?: false,
        confirmation: nil,
        input: []
      },
      %{
        id: "request_changes",
        label: "Request changes",
        style: "default",
        destructive?: false,
        confirmation: nil,
        input: [%{name: :note, type: :text, required: true, max_length: @review_note_max_length}]
      },
      %{
        id: "deny",
        label: "Deny",
        style: "destructive",
        destructive?: true,
        confirmation: "Deny this run?",
        input: [%{name: :note, type: :text, required: false, max_length: @review_note_max_length}]
      }
    ]
  end

  @doc "The action ids a card declares, in render order."
  @spec action_ids(t() | map()) :: [String.t()]
  def action_ids(%{actions: actions}) when is_list(actions), do: Enum.map(actions, & &1.id)
  def action_ids(_card), do: []

  @doc """
  Looks up a card-declared action spec by id. The dispatcher must use this so
  the set of permitted actions is card-authored, never client-asserted.
  """
  @spec fetch_action(t() | map(), String.t()) ::
          {:ok, action_spec()} | {:error, :unsupported_action}
  def fetch_action(%{actions: actions}, action_id)
      when is_list(actions) and is_binary(action_id) do
    case Enum.find(actions, &(&1.id == action_id)) do
      nil -> {:error, :unsupported_action}
      spec -> {:ok, spec}
    end
  end

  def fetch_action(_card, _action_id), do: {:error, :unsupported_action}

  @doc """
  True when an action spec is navigation-only (carries a `:route`). Such actions
  are dispatched for audit but perform no runtime mutation.
  """
  @spec navigation_action?(action_spec() | map()) :: boolean()
  def navigation_action?(%{route: route}) when not is_nil(route), do: true
  def navigation_action?(_spec), do: false

  @doc """
  Deterministically validates submitted params against an action spec's declared
  input fields. Returns normalized atom-keyed params on success. Errors are
  structured `{reason, field_name}` so callers can map them to stable strings.
  """
  @spec validate_action_params(action_spec() | map(), map()) ::
          {:ok, map()} | {:error, {:required | :too_long | :invalid, atom()}}
  def validate_action_params(%{input: input}, params)
      when is_list(input) and is_map(params) do
    Enum.reduce_while(input, {:ok, %{}}, fn field, {:ok, acc} ->
      case validate_field(field, params) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field.name, value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def validate_action_params(%{input: input}, _params) when is_list(input),
    do: {:error, {:invalid, :params}}

  defp validate_field(%{name: name, type: :text} = field, params) do
    value = normalize_text(Map.get(params, Atom.to_string(name)) || Map.get(params, name))
    required = Map.get(field, :required, false)
    max_length = Map.get(field, :max_length)

    cond do
      is_nil(value) and required -> {:error, {:required, name}}
      is_nil(value) -> {:ok, nil}
      is_integer(max_length) and String.length(value) > max_length -> {:error, {:too_long, name}}
      true -> {:ok, value}
    end
  end

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_text(_value), do: nil

  defp base(type, attrs) do
    workspace_id = attrs.workspace_id
    session_id = attrs.session_id
    now = attrs.now

    %{
      id: id(type, workspace_id, session_id),
      type: type,
      source: Map.get(attrs, :source, "devide"),
      kind: Map.get(attrs, :kind, default_kind(type)),
      status: Map.get(attrs, :status, "open"),
      priority: attrs.priority,
      user_id: attrs.user_id,
      workspace_id: workspace_id,
      workspace_name: attrs.workspace_name,
      resource:
        Map.get(attrs, :resource, %{
          type: "workspace",
          id: workspace_id,
          label: attrs.workspace_name
        }),
      session_id: session_id,
      title: attrs.title,
      body: attrs.body,
      action: attrs.action,
      secondary_actions: Map.get(attrs, :secondary_actions, []),
      actions: Map.get(attrs, :actions, []),
      context: strip_nil_values(Map.get(attrs, :context, %{})),
      meta: attrs.meta,
      created_at: now,
      updated_at: now,
      expires_at: Map.get(attrs, :expires_at)
    }
    |> remove_nil_meta()
  end

  # Normalized `kind` mirrors the legacy `type` but reads as a producer-agnostic
  # verb so later producers (CI, incidents, deploys) can reuse the vocabulary.
  defp default_kind(:needs_review), do: "approval_required"
  defp default_kind(:in_progress), do: "in_progress"
  defp default_kind(:connection_issue), do: "connection_issue"
  defp default_kind(:workspace_idle), do: "workspace_idle"

  defp binary_session(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp binary_session(_value), do: nil

  defp resume_action_spec(workspace_id, session_id) do
    navigation_action_spec(
      "resume",
      "Resume session",
      {:session_detail, workspace_id, session_id}
    )
  end

  # A route-only navigation action: dispatched for audit, no runtime mutation.
  # Normalized mirror of the legacy `action`/route so clients can prefer `actions`.
  defp navigation_action_spec(id, label, route) do
    %{
      id: id,
      label: label,
      style: "primary",
      destructive?: false,
      confirmation: nil,
      input: [],
      route: route
    }
  end

  defp connection_action_spec(reason, workspace_id)
       when reason in [:token_revoked, :invalid_token, :pairing_expired, :join_failed] do
    navigation_action_spec("pair", "Pair again", {:pair_workspace, workspace_id})
  end

  defp connection_action_spec(_reason, workspace_id) do
    navigation_action_spec("retry", "Retry", {:retry_workspace, workspace_id})
  end

  defp strip_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
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
