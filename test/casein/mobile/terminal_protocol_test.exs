defmodule Casein.Mobile.TerminalProtocolTest do
  use ExUnit.Case, async: true

  alias Casein.Mobile.TerminalProtocol

  test "freezes the read-only control and channel vocabulary" do
    assert TerminalProtocol.schema() == "mobile_terminal_v1"
    assert TerminalProtocol.mode() == "read"

    assert TerminalProtocol.control_events() ==
             ~w(terminal_create terminal_delete terminal_refresh)

    assert TerminalProtocol.channel_events() ==
             ~w(terminal_baseline terminal_output terminal_cutoff)

    assert TerminalProtocol.rejected_channel_events() ==
             ~w(terminal_input terminal_paste terminal_query)
  end

  test "baseline is bounded base64 with explicit identity and offsets" do
    payload =
      TerminalProtocol.baseline(%{
        lease_id: "lease-1",
        lifecycle_generation: "life-1",
        connection_generation: "conn-1",
        stream_generation: "stream-1",
        offset: 7,
        bytes: <<0, 255, 65>>,
        truncated: true
      })

    assert payload["schema"] == "mobile_terminal_v1"
    assert payload["event"] == "terminal_baseline"
    assert payload["offset"] == 7
    assert payload["next_offset"] == 10
    assert payload["bytes_base64"] == "AP9B"
    assert payload["truncated"] == true
    refute Map.has_key?(payload, "bytes")
  end

  test "oversized byte payload is rejected before encoding" do
    assert_raise ArgumentError, fn ->
      TerminalProtocol.output(%{
        lease_id: "lease-1",
        lifecycle_generation: "life-1",
        connection_generation: "conn-1",
        stream_generation: "stream-1",
        offset: 0,
        bytes: :binary.copy(<<0>>, TerminalProtocol.max_payload_bytes() + 1)
      })
    end
  end

  test "unknown failures collapse to privacy-safe unavailable" do
    assert TerminalProtocol.error("read_only")["reason"] == "read_only"
    assert TerminalProtocol.error("raw adapter output secret")["reason"] == "unavailable"
  end

  test "control replies carry metadata and channel identity" do
    reply =
      TerminalProtocol.control_reply(
        "created",
        %{"id" => "lease-1", "lifecycle_generation" => "life-1"},
        %{"token" => "returned-once", "expires_at" => "2026-08-05T00:00:00Z"}
      )

    assert reply["channel_topic"] == "mobile_terminal:lease-1"
    assert reply["mode"] == "read"
  end
end
