defmodule Casein.Mobile.FeedTimingRecorderTest do
  use ExUnit.Case, async: false

  alias Casein.Mobile.FeedTiming
  alias Casein.Mobile.FeedTimingRecorder

  @event [:casein, :mobile, :feed, :stage]

  test "retains a bounded chronological window with only fixed schema fields" do
    recorder = start_recorder(3)
    generation = generation()
    timing = timing(generation)

    timing = FeedTiming.emit(timing, :token_verified, reason_code: :user_token)
    timing = FeedTiming.emit(timing, :mobile_join_started, outcome: :started)
    timing = FeedTiming.emit(timing, :mobile_join_replied, reason_code: :mobile_join)
    _timing = FeedTiming.emit(timing, :snapshot_rendered, reason_code: :rendered)

    assert FeedTimingRecorder.capacity(recorder) == 3

    records = FeedTimingRecorder.snapshot_for(recorder, 10)

    assert Enum.map(records, & &1.metadata.stage) == [
             :mobile_join_started,
             :mobile_join_replied,
             :snapshot_rendered
           ]

    assert Enum.all?(records, fn record ->
             Map.keys(record) |> Enum.sort() ==
               [:measurements, :metadata, :recorded_at_ms] and
               is_integer(record.recorded_at_ms) and
               record.metadata.connection_generation == generation
           end)
  end

  test "sanitizes arbitrary telemetry and drops invalid generations" do
    recorder = start_recorder(10)
    generation = generation()
    secret = "workspace=private&token=do-not-store"

    measurements = %{
      duration_ms: 1.25,
      elapsed_ms: 3.5,
      count: 2,
      raw_content: secret
    }

    metadata = %{
      schema_version: 1,
      component: :server,
      platform: :ios,
      cycle: :cold,
      stage: :observer_snapshot,
      outcome: :succeeded,
      reason_code: :rendered,
      connection_generation: generation,
      workspace_id: secret,
      raw_error: secret
    }

    :telemetry.execute(@event, measurements, metadata)

    :telemetry.execute(
      @event,
      measurements,
      %{metadata | connection_generation: secret}
    )

    assert [record] = FeedTimingRecorder.snapshot_for(recorder)
    refute inspect(record) =~ secret

    assert record.measurements == %{
             count: 2,
             duration_ms: 1.25,
             elapsed_ms: 3.5
           }

    assert Map.keys(record.metadata) |> Enum.sort() ==
             [
               :component,
               :connection_generation,
               :cycle,
               :outcome,
               :platform,
               :reason_code,
               :schema_version,
               :stage
             ]
  end

  test "captures concurrent generations independently" do
    recorder = start_recorder(100)
    generations = Enum.map(1..20, fn _index -> generation() end)

    generations
    |> Task.async_stream(
      fn generation ->
        generation
        |> timing()
        |> FeedTiming.emit(:mobile_join_started, outcome: :started)
      end,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.to_list()

    records = FeedTimingRecorder.snapshot_for(recorder, 100)

    assert length(records) == 20

    assert records
           |> Enum.map(& &1.metadata.connection_generation)
           |> MapSet.new() == MapSet.new(generations)
  end

  test "concurrent emitters cannot leave retention above capacity" do
    recorder = start_recorder(1)

    1..2_000
    |> Task.async_stream(
      fn _index ->
        generation()
        |> timing()
        |> FeedTiming.emit(:mobile_join_started, outcome: :started)
      end,
      max_concurrency: 40,
      ordered: false,
      timeout: :infinity
    )
    |> Stream.run()

    assert [_latest] = FeedTimingRecorder.snapshot_for(recorder, 1_000)
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

  defp timing(generation) do
    FeedTiming.new(%{
      "connection_generation" => generation,
      "connection_cycle" => "cold"
    })
  end

  defp generation do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
