defmodule Casein.Mobile.FeedTiming do
  @moduledoc """
  Privacy-bounded timing context for one native mobile feed connection.

  Correlation is accepted only from a 16-byte, unpadded base64url generation
  supplied during socket connect. Invalid or missing generations never affect
  authentication and do not emit generation-scoped telemetry.
  """

  @event [:casein, :mobile, :feed, :stage]
  @generation_bytes 16
  @generation_length 22
  @max_count 1_000
  @max_card_count 1_000
  @max_snapshot_json_bytes 1_000_000
  @max_duration_ms 86_400_000

  @stages [
    :token_verified,
    :mobile_join_started,
    :mobile_join_replied,
    :workspace_watch_started,
    :workspace_watch_replied,
    :session_hydration_started,
    :session_hydration_finished,
    :clarification_hydration_finished,
    :observer_snapshot,
    :projection_broadcast,
    :snapshot_rendered,
    :push_queued
  ]
  @outcomes [:started, :succeeded, :failed, :skipped]
  @reason_codes [
    :none,
    :user_token,
    :pairing_token,
    :device_link_token,
    :invalid_token,
    :mobile_join,
    :workspace_watch,
    :workspace_watched,
    :already_watched,
    :hydrated,
    :no_changes,
    :stale_hydration,
    :rendered,
    :pushed,
    :unauthorized
  ]

  @enforce_keys [:started_at, :last_at]
  defstruct enabled?: false,
            connection_generation: nil,
            cycle: :unknown,
            platform: :unknown,
            started_at: nil,
            last_at: nil

  @type t :: %__MODULE__{
          enabled?: boolean(),
          connection_generation: String.t() | nil,
          cycle: :cold | :reconnect | :origin_switch | :unknown,
          platform: :ios | :android | :unknown,
          started_at: integer(),
          last_at: integer()
        }

  @spec new(map()) :: t()
  def new(params) when is_map(params) do
    now = System.monotonic_time(:microsecond)
    generation = valid_generation(Map.get(params, "connection_generation"))

    %__MODULE__{
      enabled?:
        Map.has_key?(params, "connection_generation") or
          Map.has_key?(params, "connection_cycle"),
      connection_generation: generation,
      cycle: normalize_cycle(Map.get(params, "connection_cycle")),
      started_at: now,
      last_at: now
    }
  end

  @spec disabled() :: t()
  def disabled do
    now = System.monotonic_time(:microsecond)
    %__MODULE__{started_at: now, last_at: now}
  end

  @spec with_platform(t(), term()) :: t()
  def with_platform(%__MODULE__{} = timing, platform) do
    %{timing | platform: normalize_platform(platform)}
  end

  @doc """
  Emits one allowlisted stage and advances the stage-to-stage interval.

  Unknown stages, outcomes, reason codes, and measurements are never forwarded.
  """
  @spec emit(t(), atom(), keyword()) :: t()
  def emit(timing, stage, opts \\ [])

  def emit(%__MODULE__{enabled?: false} = timing, _stage, _opts), do: timing

  def emit(%__MODULE__{} = timing, stage, opts)
      when stage in @stages and is_list(opts) do
    now = System.monotonic_time(:microsecond)

    measurements =
      %{
        duration_ms: milliseconds(now - timing.last_at),
        elapsed_ms: milliseconds(now - timing.started_at),
        count: bounded_count(Keyword.get(opts, :count, 1), @max_count)
      }
      |> maybe_put_measurement(
        :card_count,
        Keyword.get(opts, :card_count),
        @max_card_count
      )
      |> maybe_put_measurement(
        :snapshot_json_bytes,
        Keyword.get(opts, :snapshot_json_bytes),
        @max_snapshot_json_bytes
      )

    metadata = %{
      schema_version: 1,
      component: :server,
      platform: normalize_platform(timing.platform),
      cycle: normalize_cycle(timing.cycle),
      stage: stage,
      outcome: allowlisted(Keyword.get(opts, :outcome, :succeeded), @outcomes, :failed),
      reason_code: allowlisted(Keyword.get(opts, :reason_code, :none), @reason_codes, :none),
      connection_generation: valid_generation(timing.connection_generation)
    }

    case sanitize_event(measurements, metadata) do
      {:ok, sanitized} ->
        :telemetry.execute(@event, sanitized.measurements, sanitized.metadata)
        %{timing | last_at: now}

      :error ->
        timing
    end
  end

  def emit(%__MODULE__{} = timing, _stage, _opts), do: timing

  @spec wire_context(t()) :: map()
  def wire_context(%__MODULE__{} = timing) do
    %{
      connection_generation: valid_generation(timing.connection_generation),
      connection_cycle: timing.cycle |> normalize_cycle() |> Atom.to_string()
    }
  end

  @doc """
  Returns bounded snapshot measurements.

  Canonical JSON sizing is opt-in because computing it would otherwise encode
  every hot-path snapshot twice. Soak/test callers enable it with the
  `:mobile_feed_snapshot_json_bytes` application setting.
  """
  @spec snapshot_measurements(map()) :: keyword()
  def snapshot_measurements(snapshot) when is_map(snapshot) do
    card_count =
      snapshot
      |> Map.get(:cards, Map.get(snapshot, "cards", []))
      |> case do
        cards when is_list(cards) -> length(cards)
        _cards -> 0
      end
      |> bounded_count(@max_card_count)

    measurements = [card_count: card_count]

    if Application.get_env(:casein, :mobile_feed_snapshot_json_bytes, false) do
      case snapshot_json_bytes(snapshot) do
        {:ok, bytes} ->
          Keyword.put(
            measurements,
            :snapshot_json_bytes,
            bounded_count(bytes, @max_snapshot_json_bytes)
          )

        :error ->
          measurements
      end
    else
      measurements
    end
  end

  @spec generation_valid?(term()) :: boolean()
  def generation_valid?(value), do: not is_nil(valid_generation(value))

  @doc false
  @spec sanitize_event(map(), map()) ::
          {:ok, %{measurements: map(), metadata: map()}} | :error
  def sanitize_event(
        measurements,
        %{
          schema_version: 1,
          component: :server,
          stage: stage,
          connection_generation: generation
        } = metadata
      )
      when is_map(measurements) and stage in @stages do
    with generation when is_binary(generation) <- valid_generation(generation),
         {:ok, duration_ms} <- bounded_duration(Map.get(measurements, :duration_ms)),
         {:ok, elapsed_ms} <- bounded_duration(Map.get(measurements, :elapsed_ms)) do
      sanitized_measurements =
        %{
          duration_ms: duration_ms,
          elapsed_ms: elapsed_ms,
          count: bounded_count(Map.get(measurements, :count, 1), @max_count)
        }
        |> maybe_put_measurement(
          :card_count,
          Map.get(measurements, :card_count),
          @max_card_count
        )
        |> maybe_put_measurement(
          :snapshot_json_bytes,
          Map.get(measurements, :snapshot_json_bytes),
          @max_snapshot_json_bytes
        )

      sanitized_metadata = %{
        schema_version: 1,
        component: :server,
        platform: normalize_platform(Map.get(metadata, :platform)),
        cycle: normalize_cycle(Map.get(metadata, :cycle)),
        stage: stage,
        outcome: allowlisted(Map.get(metadata, :outcome), @outcomes, :failed),
        reason_code: allowlisted(Map.get(metadata, :reason_code), @reason_codes, :none),
        connection_generation: generation
      }

      {:ok, %{measurements: sanitized_measurements, metadata: sanitized_metadata}}
    else
      _invalid -> :error
    end
  end

  def sanitize_event(_measurements, _metadata), do: :error

  defp valid_generation(value)
       when is_binary(value) and byte_size(value) == @generation_length do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} when byte_size(decoded) == @generation_bytes ->
        if Base.url_encode64(decoded, padding: false) == value, do: value

      _invalid ->
        nil
    end
  end

  defp valid_generation(_value), do: nil

  defp normalize_cycle(value) when value in ["cold", :cold], do: :cold
  defp normalize_cycle(value) when value in ["reconnect", :reconnect], do: :reconnect

  defp normalize_cycle(value) when value in ["origin_switch", :origin_switch],
    do: :origin_switch

  defp normalize_cycle(_value), do: :unknown

  defp normalize_platform(value) when value in ["ios", :ios], do: :ios
  defp normalize_platform(value) when value in ["android", :android], do: :android
  defp normalize_platform(_value), do: :unknown

  defp milliseconds(microseconds) when is_integer(microseconds) do
    microseconds
    |> max(0)
    |> Kernel./(1_000)
    |> Float.round(3)
  end

  defp bounded_duration(value) when is_number(value) and value >= 0 do
    {:ok, min(value, @max_duration_ms)}
  end

  defp bounded_duration(_value), do: :error

  defp maybe_put_measurement(measurements, _key, nil, _maximum), do: measurements

  defp maybe_put_measurement(measurements, key, value, maximum) do
    Map.put(measurements, key, bounded_count(value, maximum))
  end

  defp bounded_count(value, maximum) when is_integer(value) and value >= 0,
    do: min(value, maximum)

  defp bounded_count(_value, _maximum), do: 0

  defp snapshot_json_bytes(snapshot) do
    {:ok,
     snapshot
     |> Jason.encode_to_iodata!()
     |> IO.iodata_length()}
  rescue
    _error -> :error
  end

  defp allowlisted(value, allowed, fallback) do
    if value in allowed, do: value, else: fallback
  end
end
