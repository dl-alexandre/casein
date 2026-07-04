defmodule DevIDE.Alerts do
  @moduledoc """
  Single source of truth for which audit actions are worth surfacing as a
  discrete alert, and how they render. Consumed by both `DevIdeWeb.SessionChannel`
  (in-app banner over the live channel) and `DevIDE.Push.Dispatcher` (OS push
  when the app isn't connected) so the two delivery surfaces never drift.
  """

  alias DevIDE.Audit.Event

  @titles %{
    "run.approval_requested" => "Approval requested",
    "run.timed_out" => "Run timed out",
    "policy.blocked" => "Blocked by policy",
    "agent.blocked" => "Agent blocked"
  }

  @doc "Audit actions that should fire an alert/notification."
  @spec actions() :: [String.t()]
  def actions, do: Map.keys(@titles)

  @doc "Whether an action (or event) is alert-worthy."
  @spec alert?(String.t() | Event.t()) :: boolean()
  def alert?(%Event{action: action}), do: alert?(action)
  def alert?(action) when is_binary(action), do: Map.has_key?(@titles, action)
  def alert?(_), do: false

  @doc "Human title for an alert action, or nil if not alert-worthy."
  @spec title_for(String.t()) :: String.t() | nil
  def title_for(action) when is_binary(action), do: Map.get(@titles, action)

  @doc """
  Delivery-agnostic notification payload for an alert-worthy event. The deep-link
  target is always `workspace_id` (clients open the session detail for it).
  Returns nil for non-alert events.
  """
  @spec notification_for(Event.t()) :: map() | nil
  def notification_for(%Event{action: action} = event) do
    case Map.fetch(@titles, action) do
      {:ok, title} ->
        %{
          workspace_id: event.workspace_id,
          action: action,
          title: title,
          reason: reason_string(event.reason),
          at: event.inserted_at
        }

      :error ->
        nil
    end
  end

  defp reason_string(nil), do: nil
  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(other), do: other
end
