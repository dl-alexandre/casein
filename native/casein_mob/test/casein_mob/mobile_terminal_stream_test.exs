defmodule CaseinMob.MobileTerminalStreamTest do
  use ExUnit.Case, async: true

  alias CaseinMob.MobileTerminalStream, as: Stream

  @lease "lease-1"
  @lifecycle "lifecycle-1"
  @connection "connection-1"
  @stream "stream-1"

  setup do
    {:ok, state} =
      Stream.new(
        lease_id: @lease,
        lifecycle_generation: @lifecycle,
        connection_generation: @connection
      )

    %{state: state}
  end

  test "requires bounded non-empty connection identities" do
    assert {:error, :invalid_identity} = Stream.new(%{})

    assert {:error, :invalid_identity} =
             Stream.new(
               lease_id: String.duplicate("x", 257),
               lifecycle_generation: @lifecycle,
               connection_generation: @connection
             )
  end

  test "accepts a baseline before contiguous live output", %{state: state} do
    assert {:ok, live, "hello"} = Stream.accept(state, baseline("hello", 10))
    assert live.status == :live
    assert live.stream_generation == @stream
    assert live.next_offset == 15

    assert {:ok, next, " world"} = Stream.accept(live, output(" world", 15))
    assert next.next_offset == 21
  end

  test "rejects output before baseline and purges to a bounded resync", %{state: state} do
    assert {:resync, purged, :baseline_required} = Stream.accept(state, output("bytes", 0))
    assert_purged(purged)
  end

  test "accepts exact duplicate frames without emitting bytes twice", %{state: state} do
    assert {:ok, live, "one"} = Stream.accept(state, baseline("one", 0))
    assert {:ok, advanced, "two"} = Stream.accept(live, output("two", 3))
    assert {:duplicate, same} = Stream.accept(advanced, output("two", 3))
    assert same == advanced

    assert {:resync, _, :offset_mismatch} = Stream.accept(live, output("one", 0))

    assert {:resync, purged, :offset_mismatch} =
             Stream.accept(advanced, output("TWO", 3))

    assert_purged(purged)
  end

  test "accepts zero-length output once and treats exact replay as a duplicate", %{state: state} do
    assert {:ok, live, "abc"} = Stream.accept(state, baseline("abc", 0))
    empty = output("", 3)

    assert {:ok, accepted, ""} = Stream.accept(live, empty)
    assert accepted.next_offset == 3
    assert {:duplicate, same} = Stream.accept(accepted, empty)
    assert same == accepted

    conflicting = Map.put(empty, "truncated", true)
    assert {:resync, purged, :offset_mismatch} = Stream.accept(accepted, conflicting)
    assert_purged(purged)
  end

  test "rejects gaps, partial overlaps, and stale duplicates outside bounded ledger", %{
    state: state
  } do
    assert {:ok, live, "abc"} = Stream.accept(state, baseline("abc", 0))
    assert {:resync, gap, :offset_mismatch} = Stream.accept(live, output("x", 4))
    assert_purged(gap)

    assert {:ok, live, "abc"} = Stream.accept(state, baseline("abc", 0))
    assert {:resync, overlap, :offset_mismatch} = Stream.accept(live, output("bc", 1))
    assert_purged(overlap)
  end

  test "wrong lease, lifecycle, connection, or stream generation purges state", %{state: state} do
    assert {:ok, live, "abc"} = Stream.accept(state, baseline("abc", 0))

    cases = [
      {Map.put(output("x", 3), "lease_id", "other"), :identity_mismatch},
      {Map.put(output("x", 3), "lifecycle_generation", "other"), :identity_mismatch},
      {Map.put(output("x", 3), "connection_generation", "other"),
       :connection_generation_mismatch},
      {Map.put(output("x", 3), "stream_generation", "other"), :stream_generation_mismatch}
    ]

    Enum.each(cases, fn {payload, reason} ->
      assert {:resync, purged, ^reason} = Stream.accept(live, payload)
      assert_purged(purged)
    end)
  end

  test "validates base64, decoded cap, offsets, booleans, schema, mode, and event", %{
    state: state
  } do
    too_large = :binary.copy(<<0>>, 65_537) |> Base.encode64()

    malformed = [
      Map.put(baseline("x", 0), "bytes_base64", "***"),
      Map.put(baseline("x", 0), "bytes_base64", too_large),
      Map.put(baseline("x", 0), "next_offset", 99),
      Map.put(baseline("x", 0), "offset", -1),
      Map.put(baseline("x", 0), "truncated", "false"),
      Map.put(baseline("x", 0), "schema", "future"),
      Map.put(baseline("x", 0), "mode", "write"),
      Map.put(baseline("x", 0), "event", "terminal_query"),
      %{},
      "not a map"
    ]

    Enum.each(malformed, fn payload ->
      assert {:resync, purged, :invalid_payload} = Stream.accept(state, payload)
      assert_purged(purged)
    end)
  end

  test "accepts the exact 64 KiB decoded cap", %{state: state} do
    bytes = :binary.copy(<<42>>, 65_536)
    assert {:ok, live, ^bytes} = Stream.accept(state, baseline(bytes, 0))
    assert live.next_offset == 65_536
  end

  test "bounds duplicate metadata and stores digests rather than terminal bytes", %{state: state} do
    assert {:ok, live, "0"} = Stream.accept(state, baseline("0", 0))

    final =
      Enum.reduce(1..80, live, fn offset, acc ->
        assert {:ok, next, "x"} = Stream.accept(acc, output("x", offset))
        next
      end)

    assert map_size(final.duplicate_ledger) == 64
    assert Enum.count_until(final.duplicate_order, 65) == 64
    refute inspect(final) =~ "terminal-secret"
    assert Enum.all?(final.duplicate_ledger, fn {_key, digest} -> byte_size(digest) == 32 end)
  end

  test "validates cutoff identity and allowlisted reason, then rejects further output", %{
    state: state
  } do
    assert {:ok, live, "abc"} = Stream.accept(state, baseline("abc", 0))
    assert {:cutoff, closed, "stale_lease"} = Stream.accept(live, cutoff("stale_lease"))
    assert closed.status == :cutoff
    assert closed.stream_generation == nil
    assert closed.next_offset == nil

    assert {:resync, purged, :cutoff} = Stream.accept(closed, output("x", 3))
    assert_purged(purged)

    assert {:resync, _, :invalid_payload} = Stream.accept(live, cutoff("raw internal error"))

    assert {:resync, _, :identity_mismatch} =
             Stream.accept(live, Map.put(cutoff("stale_lease"), "lease_id", "other"))
  end

  test "a fresh baseline can recover after resync", %{state: state} do
    assert {:resync, purged, :baseline_required} = Stream.accept(state, output("bad", 2))
    assert {:ok, recovered, "fresh"} = Stream.accept(purged, baseline("fresh", 50))
    assert recovered.next_offset == 55
  end

  defp baseline(bytes, offset), do: frame("terminal_baseline", bytes, offset)
  defp output(bytes, offset), do: frame("terminal_output", bytes, offset)

  defp frame(event, bytes, offset) do
    %{
      "schema" => "mobile_terminal_v1",
      "event" => event,
      "mode" => "read",
      "lease_id" => @lease,
      "lifecycle_generation" => @lifecycle,
      "connection_generation" => @connection,
      "stream_generation" => @stream,
      "offset" => offset,
      "next_offset" => offset + byte_size(bytes),
      "bytes_base64" => Base.encode64(bytes),
      "truncated" => false
    }
  end

  defp cutoff(reason) do
    %{
      "schema" => "mobile_terminal_v1",
      "event" => "terminal_cutoff",
      "lease_id" => @lease,
      "connection_generation" => @connection,
      "reason" => reason
    }
  end

  defp assert_purged(state) do
    assert Stream.awaiting_baseline?(state)
    assert state.stream_generation == nil
    assert state.next_offset == nil
    assert state.duplicate_ledger == %{}
    assert state.duplicate_order == []
  end
end
