defmodule DevIDE.Audit do
  @moduledoc """
  Audit log for sensitive UI actions and policy decisions.

  M10 ships with `DevIDE.Audit.MemoryAdapter` (capped in-memory ring). The
  shape of `Event` mirrors the planned `audit_events` table so swapping to
  an Ecto-backed adapter in M11 doesn't move callers.
  """

  alias DevIDE.Audit.Event

  @spec emit(map()) :: {:ok, Event.t()} | {:error, term()}
  def emit(attrs) when is_map(attrs) do
    event = Event.new(attrs)

    case impl().record(event) do
      :ok -> {:ok, event}
      {:error, _} = err -> err
    end
  end

  @doc "Emit and ignore failures — for fire-and-forget audit calls in LiveViews."
  @spec emit!(map()) :: Event.t() | nil
  def emit!(attrs) do
    case emit(attrs) do
      {:ok, e} -> e
      _ -> nil
    end
  end

  def list(opts \\ []), do: impl().list(opts)
  def recent_for(workspace_id, n \\ 50), do: impl().recent_for(workspace_id, n)
  def clear, do: impl().clear()

  ## Convenience helpers

  def emit_decision(%DevIDE.Policy.Decision{} = d, attrs) do
    emit!(
      Map.merge(attrs, %{
        action: action_name(d, attrs),
        decision: d.verdict,
        reason: d.reason,
        metadata: Map.merge(Map.get(attrs, :metadata, %{}), %{mode: d.mode})
      })
    )
  end

  defp action_name(%{verdict: :deny}, _), do: "policy.blocked"

  defp action_name(%{action: action}, attrs) do
    Map.get(attrs, :action) || Atom.to_string(action)
  end

  defp impl, do: Application.get_env(:dev_ide, :audit_adapter, DevIDE.Audit.MemoryAdapter)
end
