defmodule Casein.Audit.Event do
  @moduledoc """
  Single audit record structure that maps 1:1 to the `audit_events` database table.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          workspace_id: String.t() | nil,
          actor_id: String.t() | nil,
          action: String.t(),
          source: String.t() | nil,
          tool: String.t() | nil,
          target_type: String.t() | nil,
          target_ref: String.t() | nil,
          decision: :allow | :deny | nil,
          reason: atom() | nil,
          metadata: map(),
          inserted_at: DateTime.t()
        }

  @enforce_keys [:id, :action, :inserted_at]
  defstruct [
    :id,
    :workspace_id,
    :actor_id,
    :action,
    :source,
    :tool,
    :target_type,
    :target_ref,
    :decision,
    :reason,
    :inserted_at,
    metadata: %{}
  ]

  def new(attrs) do
    struct!(
      __MODULE__,
      Map.merge(
        %{id: Ecto.UUID.generate(), inserted_at: DateTime.utc_now()},
        attrs
      )
    )
  end

  @doc """
  Reconstruct an audit event from a bus-published CloudEvents signal.

  Used by `Casein.Signals.AlertsRouter` so alert routing reuses
  `Casein.Alerts` without a parallel payload shape.
  """
  @spec from_signal(Jido.Signal.t()) :: t()
  def from_signal(%Jido.Signal{} = signal) do
    data = normalize_signal_data(signal.data)

    %__MODULE__{
      id: signal.id,
      workspace_id: map_get(data, :workspace_id),
      actor_id: map_get(data, :actor_id),
      action: map_get(data, :action) || signal.type,
      source: map_get(data, :source),
      tool: map_get(data, :tool),
      target_type: map_get(data, :target_type),
      target_ref: signal.subject || map_get(data, :target_ref),
      decision: normalize_decision(map_get(data, :decision)),
      reason: normalize_reason(map_get(data, :reason)),
      metadata: normalize_metadata(map_get(data, :metadata)),
      inserted_at: inserted_at_from_signal(signal)
    }
  end

  defp normalize_signal_data(%_{} = data), do: Map.from_struct(data)
  defp normalize_signal_data(data) when is_map(data), do: data

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_decision(nil), do: nil
  defp normalize_decision(decision) when decision in [:allow, :deny], do: decision

  defp normalize_decision(decision) when is_binary(decision) do
    case decision do
      "allow" -> :allow
      "deny" -> :deny
      _ -> nil
    end
  end

  defp normalize_decision(_), do: nil

  defp normalize_reason(nil), do: nil
  defp normalize_reason(reason) when is_atom(reason), do: reason

  defp normalize_reason(reason) when is_binary(reason) do
    try do
      String.to_existing_atom(reason)
    rescue
      ArgumentError -> reason
    end
  end

  defp normalize_reason(reason), do: reason

  defp normalize_metadata(nil), do: %{}
  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_), do: %{}

  defp inserted_at_from_signal(%Jido.Signal{time: nil}), do: DateTime.utc_now()

  defp inserted_at_from_signal(%Jido.Signal{time: iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
end
