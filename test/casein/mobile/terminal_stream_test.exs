defmodule Casein.Mobile.TerminalStreamTest do
  use ExUnit.Case, async: true

  alias Casein.Mobile.{TerminalProtocol, TerminalStream}

  setup do
    start_supervised!({TerminalStream, lease_id: "lease-1"})
    |> then(&{:ok, stream: &1})
  end

  test "returns baseline before ordered live bytes", %{stream: stream} do
    assert {:ok, baseline} = TerminalStream.subscribe(stream, "conn-1")
    assert baseline.offset == 0
    assert baseline.next_offset == 0
    assert baseline.bytes == <<>>

    assert {:ok, frame} = TerminalStream.append(stream, "abc")
    assert frame.offset == 0
    assert frame.next_offset == 3

    assert_receive {:mobile_terminal_output, live}
    assert live.connection_generation == "conn-1"
    assert live.offset == baseline.next_offset
    assert live.bytes == "abc"
  end

  test "retains only the newest 64KiB with absolute offsets", %{stream: stream} do
    max = TerminalProtocol.max_payload_bytes()
    assert {:ok, _} = TerminalStream.append(stream, :binary.copy("a", max))
    assert {:ok, _} = TerminalStream.append(stream, "tail")
    assert {:ok, baseline} = TerminalStream.subscribe(stream, "conn-2")

    assert byte_size(baseline.bytes) == max
    assert baseline.offset == 4
    assert baseline.next_offset == max + 4
    assert baseline.truncated
    assert String.ends_with?(baseline.bytes, "tail")
  end

  test "each subscriber receives its own connection generation", %{stream: stream} do
    parent = self()

    spawn_link(fn ->
      assert {:ok, _} = TerminalStream.subscribe(stream, "conn-child")
      send(parent, :subscribed)

      receive do
        message -> send(parent, {:forwarded, message})
      end
    end)

    assert_receive :subscribed
    assert {:ok, _} = TerminalStream.append(stream, "x")

    assert_receive {:forwarded, {:mobile_terminal_output, frame}}
    assert frame.connection_generation == "conn-child"
  end

  test "chunks oversized owner output into independently bounded ordered frames", %{
    stream: stream
  } do
    max = TerminalProtocol.max_payload_bytes()
    assert {:ok, _} = TerminalStream.subscribe(stream, "conn-large")
    assert {:ok, last} = TerminalStream.append(stream, :binary.copy("z", max + 7))

    assert_receive {:mobile_terminal_output, first}
    assert_receive {:mobile_terminal_output, second}
    assert byte_size(first.bytes) == max
    assert byte_size(second.bytes) == 7
    assert first.offset == 0
    assert second.offset == first.next_offset
    assert last == Map.delete(second, :connection_generation)
  end

  test "cutoff purges bytes, notifies subscribers, and rejects future use", %{stream: stream} do
    assert {:ok, _} = TerminalStream.subscribe(stream, "conn-1")
    assert {:ok, _} = TerminalStream.append(stream, "secret bytes")
    assert_receive {:mobile_terminal_output, _}

    assert :ok = TerminalStream.cutoff(stream, "grant_revoked")
    assert_receive {:mobile_terminal_cutoff, "lease-1", "conn-1", "grant_revoked"}
    assert {:error, "grant_revoked"} = TerminalStream.append(stream, "later")
    assert {:error, "grant_revoked"} = TerminalStream.subscribe(stream, "conn-2")

    state = TerminalStream.snapshot(stream)
    assert state.buffer == <<>>
    assert state.subscribers == %{}
  end

  test "connection cutoff cannot kill a refreshed subscriber or purge lease bytes", %{
    stream: stream
  } do
    parent = self()

    old =
      spawn_link(fn ->
        {:ok, _} = TerminalStream.subscribe(stream, "conn-old")
        send(parent, {:ready, self()})
        forward(parent)
      end)

    assert_receive {:ready, ^old}
    assert {:ok, _} = TerminalStream.subscribe(stream, "conn-new")
    assert :ok = TerminalStream.cutoff_connection(stream, old, "grant_revoked")

    assert_receive {:forwarded, ^old,
                    {:mobile_terminal_cutoff, "lease-1", "conn-old", "grant_revoked"}}

    assert {:ok, _} = TerminalStream.append(stream, "new-only")

    assert_receive {:mobile_terminal_output,
                    %{connection_generation: "conn-new", bytes: "new-only"}}

    refute_receive {:forwarded, ^old, {:mobile_terminal_output, _}}
    assert TerminalStream.snapshot(stream).cutoff == nil
  end

  defp forward(parent) do
    receive do
      message ->
        send(parent, {:forwarded, self(), message})
        forward(parent)
    end
  end
end
