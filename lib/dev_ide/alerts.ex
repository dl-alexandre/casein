defmodule DevIDE.Alerts do
  @moduledoc """
  Single source of truth for which audit actions are worth surfacing as a
  discrete alert, and how they render. Consumed by both `DevIdeWeb.SessionChannel`
  (in-app banner over the live channel) and `DevIDE.Push.Dispatcher` (OS push
  when the app isn't connected) so the two delivery surfaces never drift.
  """

  alias DevIDE.Audit.Event

  @definitions %{
    "run.approval_requested" => %{
      type: "needs_review",
      severity: "warning",
      title: "Approval requested",
      channels: ["in_app", "push", "mobile"],
      ttl_seconds: 86_400,
      dedupe_window_seconds: 600
    },
    "run.timed_out" => %{
      type: "run_timed_out",
      severity: "warning",
      title: "Run timed out",
      channels: ["in_app", "push"],
      ttl_seconds: 86_400,
      dedupe_window_seconds: 600
    },
    "policy.blocked" => %{
      type: "policy_blocked",
      severity: "warning",
      title: "Blocked by policy",
      channels: ["in_app", "push"],
      ttl_seconds: 3_600,
      dedupe_window_seconds: 300
    },
    "agent.blocked" => %{
      type: "agent_blocked",
      severity: "warning",
      title: "Agent blocked",
      channels: ["in_app", "push"],
      ttl_seconds: 3_600,
      dedupe_window_seconds: 300
    },
    # Operator-facing: a terminal owner's tmux window size is being fought by
    # another writer (a stale draining instance that outlived a deploy, a
    # duplicate owner, or an external client). This is the "narrow column"
    # class made self-announcing — in-app drawer only, not a mobile push:
    # it's a platform/operator signal, not an end-user run event. The wide
    # dedupe window keeps a flapping deploy from spamming one card per owner.
    "terminal.size_fight" => %{
      type: "terminal_size_fight",
      severity: "warning",
      title: "Terminal size conflict",
      channels: ["in_app"],
      ttl_seconds: 3_600,
      dedupe_window_seconds: 900
    }
  }

  @doc "Audit actions that should fire an alert/notification."
  @spec actions() :: [String.t()]
  def actions, do: Map.keys(@definitions)

  @doc "Whether an action (or event) is alert-worthy."
  @spec alert?(String.t() | Event.t()) :: boolean()
  def alert?(%Event{action: action}), do: alert?(action)
  def alert?(action) when is_binary(action), do: Map.has_key?(@definitions, action)
  def alert?(_), do: false

  @doc "Human title for an alert action, or nil if not alert-worthy."
  @spec title_for(String.t()) :: String.t() | nil
  def title_for(action) when is_binary(action) do
    action
    |> definition_for()
    |> case do
      nil -> nil
      definition -> definition.title
    end
  end

  @doc "Structured alert definition for an audit action."
  @spec definition_for(String.t()) :: map() | nil
  def definition_for(action) when is_binary(action), do: Map.get(@definitions, action)

  @doc """
  Delivery-agnostic notification payload for an alert-worthy event. The deep-link
  target is always `workspace_id` (clients open the session detail for it).
  Returns nil for non-alert events.
  """
  @spec notification_for(Event.t()) :: map() | nil
  def notification_for(%Event{action: action} = event) do
    case definition_for(action) do
      nil ->
        nil

      definition ->
        %{
          workspace_id: event.workspace_id,
          action: action,
          title: definition.title,
          reason: reason_string(event.reason),
          at: event.inserted_at
        }
    end
  end

  @doc """
  Durable notification attrs for an alert-worthy audit event.

  The existing push/live channel payload remains `notification_for/1`; this
  richer shape is for the durable notification context.
  """
  @spec notification_attrs_for(Event.t(), String.t()) :: map() | nil
  def notification_attrs_for(%Event{action: action} = event, user_id) when is_binary(user_id) do
    case definition_for(action) do
      nil ->
        nil

      definition ->
        %{
          user_id: user_id,
          workspace_id: event.workspace_id,
          session_id: session_id(event),
          type: definition.type,
          severity: definition.severity,
          title: definition.title,
          body: reason_string(event.reason),
          metadata: notification_metadata(event),
          dedupe_key: dedupe_key(event, user_id, definition),
          ttl_seconds: definition.ttl_seconds,
          dedupe_window_seconds: definition.dedupe_window_seconds,
          deep_link: deep_link(event),
          channels: definition.channels,
          default_delivery: Map.new(definition.channels, &{&1, true}),
          source_type: "audit_event",
          source_id: event.id
        }
    end
  end

  defp reason_string(nil), do: nil
  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(other), do: other

  defp notification_metadata(%Event{} = event) do
    %{
      "action" => event.action,
      "actor_id" => event.actor_id,
      "target_type" => event.target_type,
      "target_ref" => event.target_ref,
      "decision" => event.decision && Atom.to_string(event.decision),
      "reason" => reason_string(event.reason),
      "audit_metadata" => event.metadata || %{}
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp dedupe_key(%Event{} = event, user_id, definition) do
    workspace_id = event.workspace_id || "global"
    target = event.target_ref || session_id(event) || "workspace"
    "#{user_id}:#{definition.type}:#{workspace_id}:#{target}"
  end

  defp deep_link(%Event{workspace_id: workspace_id}) when is_binary(workspace_id) do
    "devide://session/#{URI.encode_www_form(workspace_id)}"
  end

  defp deep_link(_event), do: nil

  defp session_id(%Event{metadata: metadata} = event) when is_map(metadata) do
    Map.get(metadata, "session_id") ||
      Map.get(metadata, :session_id) ||
      Map.get(metadata, "run_id") ||
      Map.get(metadata, :run_id) ||
      event.target_ref
  end

  defp session_id(%Event{target_ref: target_ref}), do: target_ref
end
