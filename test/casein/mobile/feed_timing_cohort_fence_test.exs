defmodule Casein.Mobile.FeedTimingCohortFenceTest do
  use ExUnit.Case, async: false

  alias Casein.Mobile.FeedTimingRecorder

  @event [:casein, :mobile, :feed, :stage]

  test "fenced finish aggregates only the open interval and preserves every unrelated row" do
    recorder = start_recorder(500)
    generations = generations(1..20)
    unrelated = generation(90)

    Enum.each(generations, &emit_record(&1, duration_ms: 1))
    emit_record(unrelated, duration_ms: 2)

    assert {:ok, fence} = FeedTimingRecorder.begin_cohort_for(recorder, :ios, :cold)

    Enum.each(generations, &emit_record(&1, duration_ms: 10))
    emit_record(unrelated, duration_ms: 20)
    emit_record(generation(91), platform: :android, duration_ms: 30)
    emit_record(generation(92), cycle: :reconnect, duration_ms: 40)

    assert {:ok, aggregate} =
             FeedTimingRecorder.finish_cohort_for(
               recorder,
               fence,
               generations,
               :ios,
               :cold
             )

    assert aggregate["expected_generation_count"] == 20
    assert aggregate["observed_generation_count"] == 21
    refute aggregate["cohort_match"]

    assert aggregate["stage_timings"]["mobile_join_replied"]["sample_count"] == 20

    remaining = FeedTimingRecorder.snapshot_for(recorder, 500)
    assert length(remaining) == 24

    assert Enum.count(remaining, &(&1.metadata.connection_generation in generations)) == 20
    assert Enum.count(remaining, &(&1.metadata.connection_generation == unrelated)) == 2

    emit_record(hd(generations), duration_ms: 50)
    assert length(FeedTimingRecorder.snapshot_for(recorder, 500)) == 25
  end

  test "finish requires exactly twenty unique canonical generations and consumes no rows on failure" do
    recorder = start_recorder(500)
    valid = generations(101..120)
    Enum.each(valid, &emit_record/1)

    invalid_requests = [
      Enum.take(valid, 19),
      valid ++ [generation(121)],
      List.replace_at(valid, 19, hd(valid)),
      List.replace_at(valid, 19, "not-canonical"),
      valid ++ "improper"
    ]

    Enum.each(invalid_requests, fn invalid ->
      assert {:ok, fence} = FeedTimingRecorder.begin_cohort_for(recorder, :ios, :cold)

      assert {:error, :invalid_request} =
               FeedTimingRecorder.finish_cohort_for(
                 recorder,
                 fence,
                 invalid,
                 :ios,
                 :cold
               )

      assert {:error, :invalid_request} =
               FeedTimingRecorder.finish_cohort_for(
                 recorder,
                 fence,
                 valid,
                 :ios,
                 :cold
               )

      assert length(FeedTimingRecorder.snapshot_for(recorder, 500)) == 20
    end)
  end

  test "same-scope begin is exclusive and an invalid finish retires the fence" do
    recorder = start_recorder(500)

    assert {:ok, fence} = FeedTimingRecorder.begin_cohort_for(recorder, :ios, :cold)

    assert {:error, :invalid_request} =
             FeedTimingRecorder.begin_cohort_for(recorder, :ios, :cold)

    assert {:error, :invalid_request} =
             FeedTimingRecorder.finish_cohort_for(recorder, fence, [], :ios, :cold)

    assert {:error, :invalid_request} =
             FeedTimingRecorder.finish_cohort_for(
               recorder,
               fence,
               generations(151..170),
               :ios,
               :cold
             )

    assert {:ok, _replacement_fence} =
             FeedTimingRecorder.begin_cohort_for(recorder, :ios, :cold)
  end

  test "active fence registry has a fixed total cap and releases capacity on finish" do
    recorder = start_recorder(500)

    scopes = [
      {:ios, :cold},
      {:ios, :reconnect},
      {:ios, :origin_switch},
      {:android, :cold}
    ]

    fences =
      Enum.map(scopes, fn {platform, cycle} ->
        assert {:ok, fence} = FeedTimingRecorder.begin_cohort_for(recorder, platform, cycle)
        {fence, platform, cycle}
      end)

    assert {:error, :invalid_request} =
             FeedTimingRecorder.begin_cohort_for(recorder, :android, :reconnect)

    {fence, platform, cycle} = hd(fences)

    assert {:error, :invalid_request} =
             FeedTimingRecorder.finish_cohort_for(recorder, fence, [], platform, cycle)

    assert {:ok, _fence} =
             FeedTimingRecorder.begin_cohort_for(recorder, :android, :reconnect)
  end

  test "abandoned fences expire lazily after one hour without sleeps" do
    clock = :atomics.new(1, signed: true)
    :ok = :atomics.put(clock, 1, 10_000)
    monotonic_ms_fun = fn -> :atomics.get(clock, 1) end
    recorder = start_recorder(500, monotonic_ms_fun: monotonic_ms_fun)
    valid = generations(171..190)

    assert {:ok, abandoned_fence} =
             FeedTimingRecorder.begin_cohort_for(recorder, :android, :reconnect)

    :ok = :atomics.put(clock, 1, 10_000 + :timer.hours(1) - 1)

    assert {:error, :invalid_request} =
             FeedTimingRecorder.begin_cohort_for(recorder, :android, :reconnect)

    :ok = :atomics.put(clock, 1, 10_000 + :timer.hours(1))

    assert {:ok, _new_fence} =
             FeedTimingRecorder.begin_cohort_for(recorder, :android, :reconnect)

    assert {:error, :invalid_request} =
             FeedTimingRecorder.finish_cohort_for(
               recorder,
               abandoned_fence,
               valid,
               :android,
               :reconnect
             )
  end

  test "foreign, stale, malformed, and scope-mismatched fences fail closed" do
    first = start_recorder(500)
    second = start_recorder(500)
    valid = generations(201..220)

    assert {:ok, first_fence} = FeedTimingRecorder.begin_cohort_for(first, :ios, :cold)
    assert {:ok, second_fence} = FeedTimingRecorder.begin_cohort_for(second, :ios, :cold)
    Enum.each(valid, &emit_record/1)

    assert {:error, :invalid_request} =
             FeedTimingRecorder.finish_cohort_for(
               second,
               first_fence,
               valid,
               :ios,
               :cold
             )

    assert {:error, :invalid_request} =
             FeedTimingRecorder.finish_cohort_for(
               second,
               :malformed,
               valid,
               :ios,
               :cold
             )

    assert {:ok, _aggregate} =
             FeedTimingRecorder.finish_cohort_for(
               second,
               second_fence,
               valid,
               :ios,
               :cold
             )

    assert {:error, :invalid_request} =
             FeedTimingRecorder.finish_cohort_for(
               first,
               first_fence,
               valid,
               :ios,
               :reconnect
             )

    assert {:error, :invalid_request} =
             FeedTimingRecorder.finish_cohort_for(
               first,
               first_fence,
               valid,
               :ios,
               :cold
             )

    assert {:error, :invalid_request} =
             FeedTimingRecorder.begin_cohort_for(first, "ios", :cold)

    assert {:error, :invalid_request} =
             FeedTimingRecorder.begin_cohort_for(first, :ios, "cold")

    stale_recorder = start_recorder(500)

    assert {:error, :invalid_request} =
             FeedTimingRecorder.finish_cohort_for(
               stale_recorder,
               first_fence,
               valid,
               :ios,
               :cold
             )
  end

  test "a fence whose bound fields are altered is retired on the first attempt" do
    recorder = start_recorder(500)
    valid = generations(301..320)
    assert {:ok, fence} = FeedTimingRecorder.begin_cohort_for(recorder, :ios, :cold)
    Enum.each(valid, &emit_record/1)

    {tag, epoch, lower_sequence, platform, cycle} = fence
    altered = {tag, epoch, lower_sequence + 1, platform, cycle}

    assert {:error, :invalid_request} =
             FeedTimingRecorder.finish_cohort_for(
               recorder,
               altered,
               valid,
               :ios,
               :cold
             )

    assert {:error, :invalid_request} =
             FeedTimingRecorder.finish_cohort_for(
               recorder,
               fence,
               valid,
               :ios,
               :cold
             )

    assert length(FeedTimingRecorder.snapshot_for(recorder, 500)) == 20
  end

  test "concurrent inserts are aggregated or retained across the upper fence, never lost" do
    recorder = start_recorder(2_000)
    generations = generations(401..420)
    task_supervisor = start_supervised!(Task.Supervisor)

    assert {:ok, fence} = FeedTimingRecorder.begin_cohort_for(recorder, :ios, :cold)
    Enum.each(generations, &emit_record(&1, duration_ms: 0))

    emitters =
      for index <- 1..400 do
        generation = Enum.at(generations, rem(index, 20))

        Task.Supervisor.async_nolink(task_supervisor, fn ->
          receive do
            :emit -> emit_record(generation, duration_ms: index)
          end
        end)
      end

    finisher =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        receive do
          :finish ->
            FeedTimingRecorder.finish_cohort_for(
              recorder,
              fence,
              generations,
              :ios,
              :cold
            )
        end
      end)

    Enum.each(emitters, &send(&1.pid, :emit))
    send(finisher.pid, :finish)

    Enum.each(emitters, &Task.await(&1, 5_000))
    assert {:ok, aggregate} = Task.await(finisher, 5_000)

    aggregated = aggregate["stage_timings"]["mobile_join_replied"]["sample_count"]
    retained = length(FeedTimingRecorder.snapshot_for(recorder, 2_000))

    assert aggregated + retained == 420
  end

  test "finish waits for a reserved event to be inserted before capturing its upper fence" do
    test_pid = self()

    before_record_insert_fun = fn ->
      send(test_pid, {:record_reserved, self()})

      receive do
        {:release_record_insert, ^test_pid} -> :ok
      end
    end

    recorder =
      start_recorder(500,
        before_record_insert_fun: before_record_insert_fun
      )

    task_supervisor = start_supervised!(Task.Supervisor)
    generations = generations(501..520)

    assert {:ok, fence} = FeedTimingRecorder.begin_cohort_for(recorder, :ios, :cold)

    emitter =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        emit_record(hd(generations), duration_ms: 7)
      end)

    assert_receive {:record_reserved, ^recorder}

    finish_tag = make_ref()

    send(
      recorder,
      {:"$gen_call", {self(), finish_tag}, {:finish_cohort, fence, generations, :ios, :cold}}
    )

    refute_receive {^finish_tag, _reply}
    send(recorder, {:release_record_insert, self()})

    assert_receive {^finish_tag, {:ok, aggregate}}
    assert Task.await(emitter, 5_000) == :ok

    assert aggregate["stage_timings"]["mobile_join_replied"]["sample_count"] == 1
    assert FeedTimingRecorder.snapshot_for(recorder, 500) == []
  end

  defp start_recorder(capacity, opts \\ []) do
    handler_id = {__MODULE__, make_ref()}

    start_supervised!(
      Supervisor.child_spec(
        {FeedTimingRecorder,
         Keyword.merge(
           [
             name: nil,
             capacity: capacity,
             handler_id: handler_id
           ],
           opts
         )},
        id: handler_id
      )
    )
  end

  defp emit_record(generation, opts \\ []) do
    :telemetry.execute(
      @event,
      %{
        duration_ms: Keyword.get(opts, :duration_ms, 10),
        elapsed_ms: 20,
        count: 1
      },
      %{
        schema_version: 1,
        component: :server,
        platform: Keyword.get(opts, :platform, :ios),
        cycle: Keyword.get(opts, :cycle, :cold),
        stage: :mobile_join_replied,
        outcome: :succeeded,
        reason_code: :mobile_join,
        connection_generation: generation
      }
    )
  end

  defp generations(range), do: Enum.map(range, &generation/1)

  defp generation(index) do
    :sha256
    |> :crypto.hash("casein-fenced-feed-timing-#{index}")
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end
end
