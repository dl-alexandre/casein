defmodule FleetCtl.Protocol.EnvelopeTest do
  use ExUnit.Case, async: true

  alias FleetCtl.Protocol.{Envelope, Messages}

  test "wrap/2 stores payload and generates ids" do
    msg = %Messages.ExecutionStarted{
      assignment_id: "a-1",
      execution_id: "e-1",
      started_at: DateTime.utc_now()
    }

    envelope = Envelope.wrap(msg, runner_id: "r-1", lease_id: "l-1")

    assert envelope.version == 1
    assert envelope.payload == msg
    assert FleetCtl.Envelope.valid_uuid?(envelope.message_id)
  end

  test "to_map/from_map round-trips output chunks with seq" do
    msg = %Messages.OutputChunk{
      assignment_id: "a-1",
      execution_id: "e-1",
      stream: "stdout",
      chunk: "hello",
      seq: 7,
      timestamp: DateTime.utc_now()
    }

    envelope = Envelope.wrap(msg, runner_id: "r-1", lease_id: "l-1")

    assert {:ok, decoded} = Envelope.from_map(Envelope.to_map(envelope))
    assert decoded.payload.seq == 7
  end
end
