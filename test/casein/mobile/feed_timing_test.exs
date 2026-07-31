defmodule Casein.Mobile.FeedTimingTest do
  use ExUnit.Case, async: false

  alias Casein.Mobile.FeedTiming
  alias Casein.Mobile.FeedTimingRecorder

  @event [:casein, :mobile, :feed, :stage]

  setup do
    previous = Application.get_env(:casein, :mobile_feed_snapshot_json_bytes)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:casein, :mobile_feed_snapshot_json_bytes)
        value -> Application.put_env(:casein, :mobile_feed_snapshot_json_bytes, value)
      end
    end)

    :ok
  end

  test "emits only the shared allowlisted schema for a validated generation" do
    generation = generation()
    attach(self())

    timing =
      %{
        "connection_generation" => generation,
        "connection_cycle" => "reconnect"
      }
      |> FeedTiming.new()
      |> FeedTiming.with_platform("ios")
      |> FeedTiming.emit(:token_verified,
        outcome: :succeeded,
        reason_code: :device_link_token,
        count: 7,
        card_count: 9,
        snapshot_json_bytes: 123
      )

    assert %{
             connection_generation: ^generation,
             connection_cycle: "reconnect"
           } = FeedTiming.wire_context(timing)

    assert_receive {:feed_stage, measurements, metadata}

    assert Map.keys(measurements) |> Enum.sort() ==
             [:card_count, :count, :duration_ms, :elapsed_ms, :snapshot_json_bytes]

    assert measurements.count == 7
    assert measurements.card_count == 9
    assert measurements.snapshot_json_bytes == 123
    assert is_float(measurements.duration_ms)
    assert is_float(measurements.elapsed_ms)
    assert measurements.elapsed_ms >= measurements.duration_ms

    assert metadata == %{
             schema_version: 1,
             component: :server,
             platform: :ios,
             cycle: :reconnect,
             stage: :token_verified,
             outcome: :succeeded,
             reason_code: :device_link_token,
             connection_generation: generation
           }
  end

  test "invalid generations and arbitrary metadata cannot leak into telemetry or payloads" do
    secret = "workspace=secret&token=do-not-emit"
    attach(self())

    timing =
      %{
        "connection_generation" => secret,
        "connection_cycle" => secret
      }
      |> FeedTiming.new()
      |> FeedTiming.emit(:token_verified,
        outcome: {:raw, secret},
        reason_code: secret,
        workspace_id: secret,
        raw_error: secret
      )

    assert FeedTiming.wire_context(timing) == %{
             connection_generation: nil,
             connection_cycle: "unknown"
           }

    refute_receive {:feed_stage, _measurements, _metadata}, 50
  end

  test "snapshot JSON sizing is absent on the unsampled path and bounded when enabled" do
    Application.put_env(:casein, :mobile_feed_snapshot_json_bytes, false)

    assert FeedTiming.snapshot_measurements(%{cards: [%{opaque: self()}]}) == [
             card_count: 1
           ]

    Application.put_env(:casein, :mobile_feed_snapshot_json_bytes, true)

    measurements =
      FeedTiming.snapshot_measurements(%{
        cards: [%{id: "one"}],
        padding: String.duplicate("x", 1_100_000)
      })

    assert measurements[:card_count] == 1
    assert measurements[:snapshot_json_bytes] == 1_000_000

    assert FeedTiming.snapshot_measurements(%{
             cards: [%{opaque: self()}]
           }) == [card_count: 1]
  end

  test "snapshot sizing can be toggled through the bounded runtime reporter API" do
    assert %{snapshot_json_bytes: true} =
             FeedTimingRecorder.configure_snapshot_sizing(true)

    assert FeedTimingRecorder.snapshot_sizing_enabled?()

    assert %{snapshot_json_bytes: false} =
             FeedTimingRecorder.configure_snapshot_sizing(false)

    refute FeedTimingRecorder.snapshot_sizing_enabled?()
  end

  test "rejects malformed generation shapes" do
    refute FeedTiming.generation_valid?(nil)
    refute FeedTiming.generation_valid?("")
    refute FeedTiming.generation_valid?(String.duplicate("a", 21))
    refute FeedTiming.generation_valid?(String.duplicate("a", 22))
    refute FeedTiming.generation_valid?(String.duplicate("a", 23))
    refute FeedTiming.generation_valid?("abcdefghijklmnopqrstu+")
    assert FeedTiming.generation_valid?(generation())
  end

  defp attach(test_pid) do
    handler = {__MODULE__, test_pid, System.unique_integer([:positive])}

    :telemetry.attach(
      handler,
      @event,
      fn _event, measurements, metadata, pid ->
        send(pid, {:feed_stage, measurements, metadata})
      end,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp generation do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
