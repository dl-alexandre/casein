defmodule Casein.Terminals.HostCapacityTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.HostCapacity

  test "reports a healthy host from one shared probe" do
    snapshot =
      HostCapacity.snapshot(
        load_reader: fn -> "4.66" end,
        nproc_reader: fn -> "32" end,
        mem_reader: fn -> "78456112" end,
        agents_reader: fn -> 3 end,
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
        agents_reader: fn -> 0 end,
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

  describe "agent budget" do
    test "a full budget is constrained with its own reason" do
      snapshot =
        HostCapacity.snapshot(
          load_reader: fn -> 1.0 end,
          nproc_reader: fn -> 32 end,
          mem_reader: fn -> 80_000_000 end,
          agents_reader: fn -> 32 end,
          max_agents: 32
        )

      assert snapshot.status == "constrained"
      assert snapshot.agent_processes == 32
      assert snapshot.max_agents == 32
      assert snapshot.agents_ok? == false
      assert snapshot.reasons == ["resident agent count is at the configured budget"]
    end

    test "a budget of zero disables the check" do
      snapshot =
        HostCapacity.snapshot(
          load_reader: fn -> 1.0 end,
          nproc_reader: fn -> 32 end,
          mem_reader: fn -> 80_000_000 end,
          agents_reader: fn -> 500 end,
          max_agents: 0
        )

      assert snapshot.healthy?
      assert snapshot.agents_ok?
    end

    test "an unavailable agent probe is unknown, never spare capacity" do
      snapshot =
        HostCapacity.snapshot(
          load_reader: fn -> 1.0 end,
          nproc_reader: fn -> 32 end,
          mem_reader: fn -> 80_000_000 end,
          agents_reader: fn -> nil end
        )

      assert snapshot.status == "unknown"
      refute snapshot.available?
      assert "agent process probe unavailable" in snapshot.reasons
    end

    test "count_agents matches every agent binary form and nothing else" do
      listing = """
      devbox /usr/local/bin/opencode
      devbox /home/devbox/.local/bin/claude.exe --resume
      devbox claude_exe
      devbox /usr/bin/node /home/devbox/.local/lib/node_modules/@openai/codex/bin/codex.js
      devbox /opt/grok/grok --sandbox x
      devbox /usr/bin/node /srv/app/server.js
      devbox bash
      devbox /usr/bin/vim claude.md
      """

      assert HostCapacity.count_agents(listing) == 5
      assert HostCapacity.count_agents("") == 0
    end
  end
end
