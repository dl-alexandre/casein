defmodule Casein.Mobile.FeedTimingAggregateTest do
  use ExUnit.Case, async: false

  alias Casein.Mobile.FeedTimingRecorder

  @event [:casein, :mobile, :feed, :stage]

  @stages ~w(
    token_verified
    mobile_join_started
    mobile_join_replied
    workspace_watch_started
    workspace_watch_replied
    session_hydration_started
    session_hydration_finished
    clarification_hydration_finished
    observer_snapshot
    projection_broadcast
    snapshot_rendered
    push_queued
  )

  @outcomes ~w(started succeeded failed skipped)

  @reasons ~w(
    none
    user_token
    pairing_token
    device_link_token
    invalid_token
    mobile_join
    workspace_watch
    workspace_watched
    already_watched
    hydrated
    no_changes
    stale_hydration
    rendered
    pushed
    unauthorized
  )

  test "returns exact fixed-schema nearest-rank summaries without requiring hydration stages" do
    recorder = start_recorder(200)
    generations = Enum.map(1..10, &generation/1)

    Enum.with_index(generations, 1)
    |> Enum.each(fn {generation, index} ->
      emit_record(generation,
        stage: :mobile_join_replied,
        duration_ms: index,
        elapsed_ms: index * 10,
        outcome: :succeeded,
        reason_code: :mobile_join,
        card_count: index,
        snapshot_json_bytes: if(index < 10, do: index * 100)
      )

      if index < 10 do
        emit_record(generation,
          stage: :token_verified,
          duration_ms: index + 100,
          elapsed_ms: index + 200,
          outcome: :started,
          reason_code: :user_token
        )
      end
    end)

    assert {:ok, aggregate} =
             FeedTimingRecorder.aggregate_for(recorder, generations, :ios, :cold)

    assert Map.keys(aggregate) |> Enum.sort() ==
             Enum.sort([
               "schema_version",
               "component",
               "platform",
               "cycle",
               "expected_generation_count",
               "observed_generation_count",
               "cohort_match",
               "stage_timings",
               "outcome_counts",
               "reason_counts",
               "optional_measurements"
             ])

    assert aggregate["schema_version"] == 1
    assert aggregate["component"] == "server"
    assert aggregate["platform"] == "ios"
    assert aggregate["cycle"] == "cold"
    assert aggregate["expected_generation_count"] == 10
    assert aggregate["observed_generation_count"] == 10
    assert aggregate["cohort_match"]

    assert Map.keys(aggregate["stage_timings"]) |> Enum.sort() == Enum.sort(@stages)

    assert aggregate["stage_timings"]["mobile_join_replied"] == %{
             "sample_count" => 10,
             "duration_ms" => %{"min" => 1, "p50" => 5, "p95" => 10, "max" => 10},
             "elapsed_ms" => %{"min" => 10, "p50" => 50, "p95" => 100, "max" => 100}
           }

    assert aggregate["stage_timings"]["token_verified"]["sample_count"] == 9

    assert aggregate["stage_timings"]["token_verified"]["duration_ms"] == %{
             "min" => 101,
             "p50" => 105,
             "p95" => nil,
             "max" => 109
           }

    assert aggregate["stage_timings"]["session_hydration_finished"] == %{
             "sample_count" => 0,
             "duration_ms" => %{"min" => nil, "p50" => nil, "p95" => nil, "max" => nil},
             "elapsed_ms" => %{"min" => nil, "p50" => nil, "p95" => nil, "max" => nil}
           }

    assert Map.keys(aggregate["outcome_counts"]) |> Enum.sort() == Enum.sort(@outcomes)
    assert aggregate["outcome_counts"]["succeeded"] == 10
    assert aggregate["outcome_counts"]["started"] == 9
    assert aggregate["outcome_counts"]["failed"] == 0
    assert aggregate["outcome_counts"]["skipped"] == 0

    assert Map.keys(aggregate["reason_counts"]) |> Enum.sort() == Enum.sort(@reasons)
    assert aggregate["reason_counts"]["mobile_join"] == 10
    assert aggregate["reason_counts"]["user_token"] == 9
    assert aggregate["reason_counts"]["none"] == 0

    assert aggregate["optional_measurements"] == %{
             "card_count" => %{
               "sample_count" => 10,
               "min" => 1,
               "p50" => 5,
               "p95" => 10,
               "max" => 10
             },
             "snapshot_json_bytes" => %{
               "sample_count" => 9,
               "min" => 100,
               "p50" => 500,
               "p95" => nil,
               "max" => 900
             }
           }
  end

  test "uses exact scoped generation sets rather than counts and filters summaries to the allowlist" do
    recorder = start_recorder(20)
    expected_present = generation(20)
    expected_missing = generation(21)
    unexpected = generation(22)

    emit_record(expected_present, duration_ms: 11)
    emit_record(unexpected, duration_ms: 99)
    emit_record(expected_missing, platform: :android, duration_ms: 77)
    emit_record(expected_missing, cycle: :reconnect, duration_ms: 88)

    assert {:ok, aggregate} =
             FeedTimingRecorder.aggregate_for(
               recorder,
               [expected_present, expected_missing],
               :ios,
               :cold
             )

    assert aggregate["expected_generation_count"] == 2
    assert aggregate["observed_generation_count"] == 2
    refute aggregate["cohort_match"]

    assert aggregate["stage_timings"]["mobile_join_replied"] == %{
             "sample_count" => 1,
             "duration_ms" => %{"min" => 11, "p50" => 11, "p95" => nil, "max" => 11},
             "elapsed_ms" => %{"min" => 20, "p50" => 20, "p95" => nil, "max" => 20}
           }
  end

  test "aggregate recursively excludes retained identities and raw record fields" do
    recorder = start_recorder(10)
    generation = generation(30)

    emit_record(generation,
      stage: :observer_snapshot,
      duration_ms: 12.5,
      elapsed_ms: 45.5,
      card_count: 3,
      snapshot_json_bytes: 456
    )

    assert {:ok, aggregate} =
             FeedTimingRecorder.aggregate_for(recorder, [generation], :ios, :cold)

    encoded = Jason.encode!(aggregate)
    refute encoded =~ generation

    forbidden_keys =
      MapSet.new([
        "connection_generation",
        "recorded_at_ms",
        "measurements",
        "metadata",
        "workspace_id",
        "session_id",
        "pane_id",
        "hmac",
        "timestamp"
      ])

    assert MapSet.disjoint?(recursive_keys(aggregate), forbidden_keys)
  end

  test "invalid, duplicate, oversized, malformed, and case-variant requests fail closed without consuming" do
    recorder = start_recorder(20)
    generation = generation(40)
    emit_record(generation)

    requests = [
      {[], :ios, :cold},
      {[generation, generation], :ios, :cold},
      {["not-a-canonical-generation"], :ios, :cold},
      {Enum.map(1..101, &generation(&1 + 100)), :ios, :cold},
      {[generation | "improper"], :ios, :cold},
      {[generation], "ios", :cold},
      {[generation], :IOS, :cold},
      {[generation], :unknown, :cold},
      {[generation], :ios, "cold"},
      {[generation], :ios, :COLD},
      {[generation], :ios, :unknown}
    ]

    Enum.each(requests, fn {generations, platform, cycle} ->
      assert {:error, :invalid_request} ==
               FeedTimingRecorder.aggregate_and_consume_for(
                 recorder,
                 generations,
                 platform,
                 cycle
               )

      assert [_record] = FeedTimingRecorder.snapshot_for(recorder)
    end)
  end

  test "aggregate-and-consume removes matched records only and repeated collection is empty" do
    recorder = start_recorder(20)
    matched = generation(50)
    unrelated = generation(51)

    emit_record(matched, duration_ms: 1)
    emit_record(matched, cycle: :reconnect, duration_ms: 2)
    emit_record(unrelated, duration_ms: 3)
    emit_record(unrelated, platform: :android, duration_ms: 4)

    assert {:ok, aggregate} =
             FeedTimingRecorder.aggregate_and_consume_for(recorder, [matched], :ios, :cold)

    assert aggregate["cohort_match"] == false
    assert aggregate["stage_timings"]["mobile_join_replied"]["sample_count"] == 1

    remaining = FeedTimingRecorder.snapshot_for(recorder, 20)
    assert [_first, _second, _third] = remaining

    refute Enum.any?(remaining, fn record ->
             record.metadata.connection_generation == matched and
               record.metadata.platform == :ios and
               record.metadata.cycle == :cold
           end)

    assert Enum.any?(remaining, fn record ->
             record.metadata.connection_generation == unrelated and
               record.metadata.platform == :ios and
               record.metadata.cycle == :cold
           end)

    assert {:ok, repeated} =
             FeedTimingRecorder.aggregate_and_consume_for(recorder, [matched], :ios, :cold)

    assert repeated["stage_timings"]["mobile_join_replied"]["sample_count"] == 0
    assert repeated["observed_generation_count"] == 1
    refute repeated["cohort_match"]
    assert FeedTimingRecorder.snapshot_for(recorder, 20) == remaining
  end

  test "concurrent records are either consumed in the bounded snapshot or retained, never accidentally lost" do
    recorder = start_recorder(500)
    matched = generation(60)
    unrelated = generation(61)
    task_supervisor = start_supervised!(Task.Supervisor)

    emit_record(matched, duration_ms: 0)
    emit_record(unrelated, platform: :android, duration_ms: 999)

    emitter_tasks =
      Enum.map(1..100, fn index ->
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          receive do
            :emit -> emit_record(matched, duration_ms: index)
          end
        end)
      end)

    aggregate_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        receive do
          :aggregate ->
            FeedTimingRecorder.aggregate_and_consume_for(recorder, [matched], :ios, :cold)
        end
      end)

    Enum.each(emitter_tasks, &send(&1.pid, :emit))
    send(aggregate_task.pid, :aggregate)

    Enum.each(emitter_tasks, &Task.await(&1, 5_000))
    assert {:ok, aggregate} = Task.await(aggregate_task, 5_000)

    remaining = FeedTimingRecorder.snapshot_for(recorder, 500)

    remaining_matched =
      Enum.count(remaining, fn record ->
        record.metadata.connection_generation == matched and
          record.metadata.platform == :ios and
          record.metadata.cycle == :cold
      end)

    aggregated_matched =
      aggregate["stage_timings"]["mobile_join_replied"]["sample_count"]

    assert aggregated_matched + remaining_matched == 101

    assert Enum.count(remaining, fn record ->
             record.metadata.connection_generation == unrelated and
               record.metadata.platform == :android
           end) == 1
  end

  defp start_recorder(capacity) do
    handler_id = {__MODULE__, make_ref()}

    start_supervised!(
      Supervisor.child_spec(
        {FeedTimingRecorder,
         [
           name: nil,
           capacity: capacity,
           handler_id: handler_id
         ]},
        id: handler_id
      )
    )
  end

  defp emit_record(generation, opts \\ []) do
    measurements = %{
      duration_ms: Keyword.get(opts, :duration_ms, 10),
      elapsed_ms: Keyword.get(opts, :elapsed_ms, 20),
      count: 1
    }

    measurements =
      Enum.reduce([:card_count, :snapshot_json_bytes], measurements, fn key, acc ->
        case Keyword.fetch(opts, key) do
          {:ok, nil} -> acc
          {:ok, value} -> Map.put(acc, key, value)
          :error -> acc
        end
      end)

    metadata = %{
      schema_version: 1,
      component: :server,
      platform: Keyword.get(opts, :platform, :ios),
      cycle: Keyword.get(opts, :cycle, :cold),
      stage: Keyword.get(opts, :stage, :mobile_join_replied),
      outcome: Keyword.get(opts, :outcome, :succeeded),
      reason_code: Keyword.get(opts, :reason_code, :mobile_join),
      connection_generation: generation
    }

    :telemetry.execute(@event, measurements, metadata)
  end

  defp generation(index) do
    :sha256
    |> :crypto.hash("casein-feed-timing-#{index}")
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end

  defp recursive_keys(value, keys \\ MapSet.new())

  defp recursive_keys(value, keys) when is_map(value) do
    Enum.reduce(value, keys, fn {key, nested}, acc ->
      acc
      |> MapSet.put(to_string(key))
      |> then(&recursive_keys(nested, &1))
    end)
  end

  defp recursive_keys(value, keys) when is_list(value) do
    Enum.reduce(value, keys, &recursive_keys/2)
  end

  defp recursive_keys(_value, keys), do: keys
end
