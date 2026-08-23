defmodule Casein.Terminals.HostCapacityTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.HostCapacity

  test "reports a healthy host from one shared probe" do
    snapshot =
      HostCapacity.snapshot(
        load_reader: fn -> "4.66" end,
        nproc_reader: fn -> "32" end,
        mem_reader: fn -> "78456112" end,
        max_load_ratio: 4.0
      )

    assert snapshot.status == "healthy"
    assert snapshot.available?
    assert snapshot.healthy?
    assert snapshot.load1 == 4.66
    assert snapshot.nproc == 32
    assert snapshot.load_limit == 128.0
    assert snapshot.mem_available_kb == 78_456_112
    assert snapshot.reasons == []
  end

  test "reports constrained capacity with an actionable reason" do
    snapshot =
      HostCapacity.snapshot(
        load_reader: fn -> 40.0 end,
        nproc_reader: fn -> 32 end,
        mem_reader: fn -> 1_000 end,
        max_load_ratio: 1.0,
        min_mem_available_kb: 2_000
      )

    assert snapshot.status == "constrained"
    refute snapshot.healthy?

    assert snapshot.reasons == [
             "load exceeds configured limit",
             "available memory is below configured minimum"
           ]
  end

  test "does not treat missing probes as spare capacity" do
    snapshot =
      HostCapacity.snapshot(
        load_reader: fn -> nil end,
        nproc_reader: fn -> nil end,
        mem_reader: fn -> nil end
      )

    assert snapshot.status == "unknown"
    refute snapshot.available?
    refute snapshot.healthy?
    assert "load probe unavailable" in snapshot.reasons
    assert "memory probe unavailable" in snapshot.reasons
  end
end
