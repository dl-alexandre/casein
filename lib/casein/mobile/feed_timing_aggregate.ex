defmodule Casein.Mobile.FeedTimingAggregate do
  @moduledoc false

  alias Casein.Mobile.FeedTiming

  @schema_version 1
  @component "server"
  @maximum_generations 100
  @maximum_records 2_000

  @platforms [:ios, :android]
  @cycles [:cold, :reconnect, :origin_switch]

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

  @optional_measurements [:card_count, :snapshot_json_bytes]

  @type request :: %{
          expected_generations: MapSet.t(String.t()),
          expected_generation_count: pos_integer(),
          platform: :ios | :android,
          cycle: :cold | :reconnect | :origin_switch
        }

  @spec validate_request(term(), term(), term()) :: {:ok, request()} | {:error, :invalid_request}
  def validate_request(generations, platform, cycle)
      when platform in @platforms and cycle in @cycles do
    with {:ok, expected_generations, expected_generation_count} <-
           validate_generations(generations, MapSet.new(), 0) do
      {:ok,
       %{
         expected_generations: expected_generations,
         expected_generation_count: expected_generation_count,
         platform: platform,
         cycle: cycle
       }}
    end
  end

  def validate_request(_generations, _platform, _cycle), do: {:error, :invalid_request}

  @spec build([{integer(), map()}], request()) ::
          {:ok, map(), [integer()]} | {:error, :invalid_request}
  def build(
        entries,
        %{
          expected_generations: %MapSet{} = expected_generations,
          expected_generation_count: expected_generation_count,
          platform: platform,
          cycle: cycle
        } = request
      )
      when is_list(entries) and is_integer(expected_generation_count) and
             expected_generation_count > 0 and expected_generation_count <= @maximum_generations and
             platform in @platforms and cycle in @cycles do
    if bounded_entries?(entries) and
         MapSet.size(expected_generations) == expected_generation_count and
         Enum.all?(expected_generations, &FeedTiming.generation_valid?/1) do
      scoped_entries = Enum.filter(entries, &scoped_entry?(&1, request))

      observed_generations =
        scoped_entries
        |> Enum.map(&entry_generation/1)
        |> MapSet.new()

      matched_entries =
        Enum.filter(scoped_entries, fn entry ->
          MapSet.member?(request.expected_generations, entry_generation(entry))
        end)

      matched_records = Enum.map(matched_entries, &entry_record/1)

      aggregate = %{
        "schema_version" => @schema_version,
        "component" => @component,
        "platform" => Atom.to_string(request.platform),
        "cycle" => Atom.to_string(request.cycle),
        "expected_generation_count" => request.expected_generation_count,
        "observed_generation_count" => MapSet.size(observed_generations),
        "cohort_match" => MapSet.equal?(request.expected_generations, observed_generations),
        "stage_timings" => stage_timings(matched_records),
        "outcome_counts" => fixed_counts(matched_records, @outcomes, :outcome),
        "reason_counts" => fixed_counts(matched_records, @reason_codes, :reason_code),
        "optional_measurements" => optional_measurements(matched_records)
      }

      {:ok, aggregate, Enum.map(matched_entries, &entry_sequence/1)}
    else
      {:error, :invalid_request}
    end
  end

  def build(_entries, _request), do: {:error, :invalid_request}

  defp bounded_entries?(entries) do
    Enum.count_until(entries, @maximum_records + 1) <= @maximum_records
  end

  defp validate_generations([], generations, count) when count > 0,
    do: {:ok, generations, count}

  defp validate_generations([generation | rest], generations, count)
       when count < @maximum_generations and is_binary(generation) do
    if FeedTiming.generation_valid?(generation) and
         not MapSet.member?(generations, generation) do
      validate_generations(rest, MapSet.put(generations, generation), count + 1)
    else
      {:error, :invalid_request}
    end
  end

  defp validate_generations(_generations, _seen, _count), do: {:error, :invalid_request}

  defp scoped_entry?(
         {sequence,
          %{
            measurements: measurements,
            metadata: %{
              platform: platform,
              cycle: cycle,
              connection_generation: generation
            }
          }},
         request
       )
       when is_integer(sequence) and is_map(measurements) and is_binary(generation) do
    platform == request.platform and cycle == request.cycle
  end

  defp scoped_entry?(_entry, _request), do: false

  defp entry_sequence({sequence, _record}), do: sequence
  defp entry_record({_sequence, record}), do: record

  defp entry_generation({_sequence, %{metadata: %{connection_generation: generation}}}),
    do: generation

  defp stage_timings(records) do
    Map.new(@stages, fn stage ->
      stage_records = Enum.filter(records, &metadata_equal?(&1, :stage, stage))

      {Atom.to_string(stage),
       %{
         "sample_count" => length(stage_records),
         "duration_ms" => measurement_summary(stage_records, :duration_ms),
         "elapsed_ms" => measurement_summary(stage_records, :elapsed_ms)
       }}
    end)
  end

  defp fixed_counts(records, values, field) do
    Map.new(values, fn value ->
      {Atom.to_string(value), Enum.count(records, &metadata_equal?(&1, field, value))}
    end)
  end

  defp metadata_equal?(%{metadata: metadata}, field, expected) when is_map(metadata),
    do: Map.get(metadata, field) == expected

  defp metadata_equal?(_record, _field, _expected), do: false

  defp optional_measurements(records) do
    Enum.reduce(@optional_measurements, %{}, fn measurement, summaries ->
      values = measurement_values(records, measurement)

      case values do
        [] ->
          summaries

        values ->
          Map.put(
            summaries,
            Atom.to_string(measurement),
            Map.put(summary(values), "sample_count", length(values))
          )
      end
    end)
  end

  defp measurement_summary(records, measurement) do
    records
    |> measurement_values(measurement)
    |> summary()
  end

  defp measurement_values(records, measurement) do
    Enum.flat_map(records, fn
      %{measurements: measurements} when is_map(measurements) ->
        case Map.fetch(measurements, measurement) do
          {:ok, value} when is_number(value) -> [value]
          _missing_or_invalid -> []
        end

      _record ->
        []
    end)
  end

  defp summary([]), do: %{"min" => nil, "p50" => nil, "p95" => nil, "max" => nil}

  defp summary(values) do
    sorted = Enum.sort(values)
    sample_count = length(sorted)

    %{
      "min" => hd(sorted),
      "p50" => nearest_rank(sorted, 0.50),
      "p95" => if(sample_count >= 10, do: nearest_rank(sorted, 0.95), else: nil),
      "max" => List.last(sorted)
    }
  end

  defp nearest_rank(sorted, percentile) do
    index = ceil(length(sorted) * percentile) - 1
    Enum.at(sorted, index)
  end
end
