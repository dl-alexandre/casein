defmodule DevIDE.Terminals.RemoteOutputStreamerTest do
  use ExUnit.Case, async: false

  alias DevIDE.Fleet.Notification
  alias DevIDE.Terminals.RemoteOutputStreamer

  @pubsub DevIde.PubSub

  setup do
    # Per-test execution_id keeps PubSub topics isolated even with async: false.
    {:ok, execution_id: "exec-test-#{System.unique_integer([:positive])}"}
  end

  defp start_streamer(execution_id) do
    {:ok, pid} = RemoteOutputStreamer.start_link(execution_id: execution_id, subscriber: self())
    # Drain the initial :replay self-message and any cached chunks.
    Process.sleep(20)
    flush_term_data()
    pid
  end

  defp broadcast_chunk(execution_id, stream, chunk, seq) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "fleet:executions:#{execution_id}",
      {DevIDE.Fleet.LocalRunnerAdapter,
       %Notification{
         kind: :output_chunk,
         execution_id: execution_id,
         payload: %{stream: stream, chunk: chunk, seq: seq, byte_size: byte_size(chunk)},
         occurred_at: DateTime.utc_now()
       }}
    )
  end

  defp flush_term_data(acc \\ []) do
    receive do
      {:term_data, data} -> flush_term_data([data | acc])
      {:term_exit, _} -> flush_term_data(acc)
    after
      30 -> Enum.reverse(acc)
    end
  end

  test "passes through in-order chunks", %{execution_id: eid} do
    _pid = start_streamer(eid)

    broadcast_chunk(eid, "stdout", "one", 1)
    broadcast_chunk(eid, "stdout", "two", 2)
    broadcast_chunk(eid, "stdout", "three", 3)

    assert ["one", "two", "three"] = flush_term_data()
  end

  test "stdout and stderr have independent seq counters", %{execution_id: eid} do
    _pid = start_streamer(eid)

    # If the streamer tracked one global last_seq, the stderr=1 after
    # stdout=5 would be dropped as a regression. The per-stream map fixes that.
    broadcast_chunk(eid, "stdout", "out-1", 1)
    broadcast_chunk(eid, "stdout", "out-2", 2)
    broadcast_chunk(eid, "stdout", "out-3", 3)
    broadcast_chunk(eid, "stdout", "out-4", 4)
    broadcast_chunk(eid, "stdout", "out-5", 5)
    broadcast_chunk(eid, "stderr", "err-1", 1)
    broadcast_chunk(eid, "stderr", "err-2", 2)

    out = flush_term_data()
    assert "out-1" in out
    assert "out-5" in out
    assert "err-1" in out, "stderr chunk seq=1 must not be treated as a regression of stdout=5"
    assert "err-2" in out
  end

  test "drops exact-duplicate seq", %{execution_id: eid} do
    _pid = start_streamer(eid)

    broadcast_chunk(eid, "stdout", "first", 1)
    broadcast_chunk(eid, "stdout", "first-dupe", 1)

    out = flush_term_data()
    assert "first" in out
    refute "first-dupe" in out
  end

  test "emits gap marker and continues when seq skips", %{execution_id: eid} do
    _pid = start_streamer(eid)

    broadcast_chunk(eid, "stdout", "a", 1)
    broadcast_chunk(eid, "stdout", "b", 2)
    broadcast_chunk(eid, "stdout", "e", 5)

    out = flush_term_data()
    assert "a" in out
    assert "b" in out
    assert "e" in out

    gap = Enum.find(out, &String.contains?(&1, "output gap"))
    assert gap, "expected a gap marker after the skipped seqs"
    assert gap =~ "2 chunk(s) lost"
    assert gap =~ "between seq 3 and 4"
  end

  test "passes through chunks with nil seq (legacy producer)", %{execution_id: eid} do
    _pid = start_streamer(eid)

    broadcast_chunk(eid, "stdout", "legacy-1", nil)
    broadcast_chunk(eid, "stdout", "legacy-2", nil)

    out = flush_term_data()
    assert "legacy-1" in out
    assert "legacy-2" in out
  end
end
