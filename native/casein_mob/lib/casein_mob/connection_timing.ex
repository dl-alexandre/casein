defmodule CaseinMob.ConnectionTiming do
  @moduledoc """
  Privacy-bounded native feed stage timing.

  Events use the shared `[:casein, :mobile, :feed, :stage]` schema. Metadata is
  built from a fixed allowlist; connection URLs, tokens, origin/workspace ids,
  payload contents, and raw errors are never emitted.
  """

  require Logger

  @event [:casein, :mobile, :feed, :stage]
  @boot_key {__MODULE__, :boot_context}
  @snapshot_context_key :__casein_feed_timing__
  @generation_bytes 16
  @generation_length 22
  @max_native_timing_ms 2_147_483_647
  @max_card_count 1_000
  @max_snapshot_json_bytes 1_000_000
  @cycles [:cold, :reconnect, :origin_switch]
  @outcomes [:started, :succeeded, :failed, :skipped]
  @reason_codes [
    :none,
    :no_configuration,
    :transport_disconnected,
    :dns_resolved,
    :dns_ip_literal,
    :dns_invalid_url,
    :dns_resolution_failed,
    :invalid_payload,
    :transport_not_ready,
    :connection_generation_mismatch,
    :connection_cycle_mismatch,
    :invalid_snapshot_version,
    :invalid_origin,
    :unknown_origin,
    :origin_mismatch,
    :state_unavailable,
    :snapshot_version_regression
  ]
  @stages [
    :app_start,
    :profile_restored,
    :dns_resolved,
    :dependencies_ready,
    :client_started,
    :database_ready,
    :root_started,
    :connect_requested,
    :transport_connected,
    :mobile_join_replied,
    :snapshot_received,
    :snapshot_accepted,
    :snapshot_rejected,
    :first_cards_render_ready,
    :no_configuration,
    :disconnected
  ]
  # A connection generation has one lifecycle path, but it can legitimately
  # receive equal-version refreshes and multiple rejected snapshots. Keep
  # snapshot observations repeatable while suppressing duplicate lifecycle
  # callbacks from native or transport races.
  @one_shot_stages MapSet.new(
                     @stages -- [:snapshot_received, :snapshot_accepted, :snapshot_rejected]
                   )
  @stage_aliases %{
    configuration_restored: :profile_restored,
    dns_ready: :dns_resolved,
    reconnect_requested: :connect_requested,
    authoritative_cards_joined: :mobile_join_replied
  }

  @type cycle :: :cold | :reconnect | :origin_switch
  @type context :: %{
          generation: String.t(),
          cycle: cycle(),
          started_at: integer(),
          last_at: integer(),
          seen_stages: MapSet.t(atom())
        }

  @spec start_boot() :: integer()
  def start_boot do
    with_boot_lock(fn ->
      context = new_context(:cold)
      context = record(context, :app_start, outcome: :started)
      :persistent_term.put(@boot_key, context)
      context.started_at
    end)
  end

  @spec boot_started_at() :: integer() | nil
  def boot_started_at do
    case boot_context() do
      %{started_at: started_at} -> started_at
      _ -> nil
    end
  end

  @spec boot_context() :: context() | nil
  def boot_context, do: :persistent_term.get(@boot_key, nil)

  @doc """
  Atomically hand the cold timing chain from app boot to the session client.

  Exactly one caller can receive the context. Once handed off, app-side
  `boot_stage/2` calls are ignored instead of forking a second chain.
  """
  @spec take_boot_context() :: context() | nil
  def take_boot_context do
    with_boot_lock(fn ->
      context = boot_context()
      :persistent_term.erase(@boot_key)
      context
    end)
  end

  @spec boot_stage(atom(), keyword()) :: :ok
  def boot_stage(stage, opts \\ []) do
    with_boot_lock(fn ->
      case boot_context() do
        %{generation: _generation} = context ->
          :persistent_term.put(@boot_key, record(context, stage, opts))
          :ok

        _already_handed_off ->
          :ok
      end
    end)
  end

  @spec new_context(cycle()) :: context()
  def new_context(cycle) when cycle in @cycles do
    now = now()

    %{
      generation: new_generation(),
      cycle: cycle,
      started_at: now,
      last_at: now,
      seen_stages: MapSet.new()
    }
  end

  @spec record(context(), atom(), keyword()) :: context()
  def record(context, stage, opts \\ [])

  def record(context, stage, opts) when is_map(context) and is_list(opts) do
    stage = Map.get(@stage_aliases, stage, stage)

    with true <- valid_context?(context),
         true <- stage in @stages,
         false <- duplicate_stage?(context, stage),
         observed_at when is_integer(observed_at) <- Keyword.get(opts, :observed_at, now()),
         true <- valid_observation?(context, observed_at) do
      %{started_at: started_at, last_at: last_at} = context
      measurements = measurements(opts, observed_at, started_at, last_at)
      metadata = metadata(context, stage, opts)

      :telemetry.execute(@event, measurements, metadata)

      emit_log(
        metadata.platform,
        metadata.connection_generation,
        metadata.cycle,
        stage,
        measurements.duration_ms,
        measurements.elapsed_ms,
        metadata.outcome,
        metadata.reason_code
      )

      context
      |> Map.put(:last_at, observed_at)
      |> mark_stage_seen(stage)
    else
      _invalid_or_duplicate ->
        context
    end
  end

  def record(context, _stage, _opts), do: context

  @doc """
  Attach an in-memory timing context to an accepted snapshot.

  The atom-keyed envelope is local-only and is not persisted by the card cache
  or sent over the network.
  """
  @spec decorate_snapshot(map(), context()) :: map()
  def decorate_snapshot(payload, context) when is_map(payload) and is_map(context) do
    Map.put(payload, @snapshot_context_key, context)
  end

  @spec snapshot_stage(map(), atom(), keyword()) :: :ok
  def snapshot_stage(payload, stage, opts \\ []) when is_map(payload) do
    case Map.get(payload, @snapshot_context_key) do
      %{generation: _generation} = context ->
        _context = record(context, stage, opts)
        :ok

      _ ->
        :ok
    end
  end

  @spec snapshot_generation(map()) :: String.t() | nil
  def snapshot_generation(payload) when is_map(payload) do
    case Map.get(payload, @snapshot_context_key) do
      %{generation: generation} when is_binary(generation) -> valid_generation(generation)
      _ -> nil
    end
  end

  @doc "Canonical JSON size for sampled snapshots; never returns payload data."
  @spec snapshot_json_bytes(map()) :: non_neg_integer() | nil
  def snapshot_json_bytes(payload) when is_map(payload) do
    payload
    |> Map.delete(@snapshot_context_key)
    |> Jason.encode()
    |> case do
      {:ok, encoded} -> min(byte_size(encoded), @max_snapshot_json_bytes)
      {:error, _reason} -> nil
    end
  rescue
    _ -> nil
  end

  @doc false
  def reset do
    with_boot_lock(fn ->
      :persistent_term.erase(@boot_key)
      :ok
    end)
  end

  defp measurements(opts, observed_at, started_at, last_at) do
    %{
      duration_ms: milliseconds(observed_at - last_at),
      elapsed_ms: milliseconds(observed_at - started_at),
      count: 1
    }
    |> maybe_put_measurement(:card_count, Keyword.get(opts, :card_count))
    |> maybe_put_measurement(:snapshot_json_bytes, Keyword.get(opts, :snapshot_json_bytes))
  end

  defp maybe_put_measurement(measurements, key, value)
       when is_integer(value) and value >= 0,
       do: Map.put(measurements, key, bounded_measurement(key, value))

  defp maybe_put_measurement(measurements, _key, _value), do: measurements

  defp bounded_measurement(:card_count, value), do: min(value, @max_card_count)

  defp bounded_measurement(:snapshot_json_bytes, value),
    do: min(value, @max_snapshot_json_bytes)

  defp bounded_measurement(_key, value), do: value

  defp metadata(context, stage, opts) do
    %{
      schema_version: 1,
      component: :native,
      platform: platform(),
      cycle: context.cycle,
      stage: stage,
      outcome: allowlisted(Keyword.get(opts, :outcome, :succeeded), @outcomes, :failed),
      reason_code: allowlisted(Keyword.get(opts, :reason_code, :none), @reason_codes, :none),
      connection_generation: valid_generation(context.generation)
    }
    |> maybe_put_metadata(:snapshot_version, Keyword.get(opts, :snapshot_version))
  end

  defp maybe_put_metadata(metadata, key, value) when is_integer(value) and value >= 0,
    do: Map.put(metadata, key, value)

  defp maybe_put_metadata(metadata, _key, _value), do: metadata

  defp allowlisted(value, allowed, fallback) do
    if value in allowed, do: value, else: fallback
  end

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

  defp valid_context?(
         %{
           generation: generation,
           cycle: cycle,
           started_at: started_at,
           last_at: last_at
         } = context
       ) do
    seen_stages = Map.get(context, :seen_stages, MapSet.new())

    is_binary(generation) and valid_generation(generation) == generation and cycle in @cycles and
      is_integer(started_at) and is_integer(last_at) and last_at >= started_at and
      valid_seen_stages?(seen_stages)
  end

  defp valid_context?(_context), do: false

  defp valid_seen_stages?(%MapSet{map: map}) when is_map(map) do
    Enum.all?(Map.keys(map), &(&1 in @stages))
  end

  defp valid_seen_stages?(_seen_stages), do: false

  defp valid_observation?(%{started_at: started_at, last_at: last_at}, observed_at) do
    duration = observed_at - last_at
    elapsed = observed_at - started_at
    max_microseconds = @max_native_timing_ms * 1_000

    duration >= 0 and elapsed >= duration and elapsed <= max_microseconds
  end

  defp duplicate_stage?(context, stage) do
    stage in @one_shot_stages and
      MapSet.member?(Map.get(context, :seen_stages, MapSet.new()), stage)
  end

  defp mark_stage_seen(context, stage) do
    Map.update(context, :seen_stages, MapSet.new([stage]), &MapSet.put(&1, stage))
  end

  defp emit_log(
         platform,
         generation,
         cycle,
         stage,
         duration_ms,
         elapsed_ms,
         outcome,
         reason_code
       )
       when platform in [:ios, :android] do
    if valid_native_stage_envelope?(generation, duration_ms, elapsed_ms) do
      emit_native_stage(
        native_nif(),
        generation,
        cycle,
        stage,
        duration_ms,
        elapsed_ms,
        outcome,
        reason_code
      )
    else
      :ok
    end
  end

  defp emit_log(
         _platform,
         generation,
         cycle,
         stage,
         duration_ms,
         elapsed_ms,
         outcome,
         reason_code
       ) do
    Logger.info(
      "mobile_feed_stage connection_generation=#{generation || "uncorrelated"} " <>
        "cycle=#{cycle} stage=#{stage} " <>
        "duration_ms=#{duration_ms} elapsed_ms=#{elapsed_ms} " <>
        "outcome=#{outcome} reason_code=#{reason_code}"
    )

    :ok
  end

  defp emit_native_stage(
         nif,
         generation,
         cycle,
         stage,
         duration_ms,
         elapsed_ms,
         outcome,
         reason_code
       ) do
    case nif.log_mobile_feed_stage(
           generation,
           cycle,
           stage,
           duration_ms,
           elapsed_ms,
           outcome,
           reason_code
         ) do
      :ok -> :ok
      _unexpected -> :ok
    end

    :ok
  rescue
    # Timing is observational. Native sink failures must never interrupt the
    # authoritative feed or expose an exception that may contain endpoint data.
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp platform do
    if System.get_env("MOB_BEAMS_DIR") do
      native_platform(native_nif())
    else
      :unknown
    end
  end

  defp native_platform(nif) do
    case nif.platform() do
      platform when platform in [:ios, :android] -> platform
      _ -> :unknown
    end
  rescue
    # Platform detection is telemetry-only and cannot block feed startup.
    _error -> :unknown
  catch
    _kind, _reason -> :unknown
  end

  defp native_nif do
    Application.get_env(:casein_mob, :connection_timing_native_nif, :mob_nif)
  end

  defp valid_native_stage_envelope?(generation, duration_ms, elapsed_ms) do
    is_binary(generation) and valid_generation(generation) == generation and
      is_number(duration_ms) and
      duration_ms >= 0 and duration_ms <= @max_native_timing_ms and is_number(elapsed_ms) and
      elapsed_ms >= duration_ms and elapsed_ms <= @max_native_timing_ms
  end

  defp new_generation do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp now, do: System.monotonic_time(:microsecond)

  defp milliseconds(microseconds) when is_integer(microseconds) do
    microseconds
    |> Kernel./(1_000)
    |> Float.round(3)
  end

  defp with_boot_lock(fun) when is_function(fun, 0) do
    # :global lock ids are {shared_resource, requester_id}.
    :global.trans({{@boot_key, :handoff}, self()}, fun)
  end
end
