defmodule Casein.Mobile.Observability do
  @moduledoc """
  Privacy-bounded observations for origin-qualified mobile resume flows.

  This is intentionally not general analytics. The client may report only a
  small vocabulary of lifecycle outcomes, and arbitrary payload keys are
  discarded before the event reaches telemetry or the audit spine.
  """

  alias Casein.Audit

  @events ~w(
    origin_switch authoritative_refresh locator_fallback intervention
    attention_view attention_action notification stale_recovery
  )
  @outcomes ~w(
    started succeeded failed rejected unavailable
    handled dismissed escalated opened deduped desktop_required
  )
  @fallback_levels ~w(exact task_session workspace action_center none)
  @stale_age_buckets ~w(live under_5m under_1h under_24h over_24h unknown)
  @duration_buckets ~w(under_10s under_1m under_5m under_1h over_1h unknown)
  @action_kinds ~w(viewed handled dismissed escalated review follow_up pwa)
  @max_id_length 240

  @spec record(map(), map()) :: :ok | {:error, atom()}
  def record(context, params) when is_map(context) and is_map(params) do
    with {:ok, event} <- member(params, "event", @events),
         {:ok, outcome} <- member(params, "outcome", @outcomes),
         {:ok, fallback_level} <-
           optional_member(params, "fallback_level", @fallback_levels),
         {:ok, stale_age_bucket} <-
           optional_member(params, "stale_age_bucket", @stale_age_buckets),
         {:ok, awareness_latency_bucket} <-
           optional_member(params, "awareness_latency_bucket", @duration_buckets),
         {:ok, time_to_action_bucket} <-
           optional_member(params, "time_to_action_bucket", @duration_buckets),
         {:ok, action_kind} <- optional_member(params, "action_kind", @action_kinds),
         {:ok, card_id} <- optional_id(params, "card_id") do
      metadata =
        %{
          "event" => event,
          "outcome" => outcome,
          "fallback_level" => fallback_level,
          "stale_age_bucket" => stale_age_bucket,
          "awareness_latency_bucket" => awareness_latency_bucket,
          "time_to_action_bucket" => time_to_action_bucket,
          "action_kind" => action_kind,
          "card_id" => card_id,
          "origin_id" => Map.get(context, :origin_id),
          "device_link_id" => Map.get(context, :device_link_id),
          "platform" => Map.get(context, :platform)
        }
        |> compact()

      :telemetry.execute(
        [:casein, :mobile, :observation],
        %{count: 1},
        metadata
      )

      Audit.emit!(%{
        action: "mobile." <> event,
        actor_id: Map.get(context, :user_id),
        workspace_id: Map.get(context, :workspace_id),
        target_type: "mobile_resume",
        target_ref: card_id,
        metadata: metadata
      })

      :ok
    end
  end

  def record(_context, _params), do: {:error, :invalid_payload}

  defp member(params, key, allowed) do
    case Map.get(params, key) do
      value -> if(value in allowed, do: {:ok, value}, else: {:error, :invalid_observation})
    end
  end

  defp optional_member(params, key, allowed) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      value -> if(value in allowed, do: {:ok, value}, else: {:error, :invalid_observation})
    end
  end

  defp optional_id(params, key) do
    case Map.get(params, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        value = String.trim(value)

        if value != "" and String.length(value) <= @max_id_length,
          do: {:ok, value},
          else: {:error, :invalid_observation}

      _ ->
        {:error, :invalid_observation}
    end
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end
end
