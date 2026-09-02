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
      devbox 101 1 /usr/local/bin/opencode
      devbox 102 1 /home/devbox/.local/bin/claude.exe --resume
      devbox 103 1 claude_exe
      devbox 104 1 /usr/bin/node /home/devbox/.local/lib/node_modules/@openai/codex/bin/codex.js
      devbox 105 1 /opt/grok/grok --sandbox x
      devbox 106 1 /usr/bin/node /srv/app/server.js
      devbox 107 1 bash
      devbox 108 1 /usr/bin/vim claude.md
      """

      assert HostCapacity.count_agents(listing) == 5
      assert HostCapacity.count_agents("") == 0
    end

    test "count_d_state counts only a leading D" do
      # R+, Ss, DN, D< — only a leading D is uninterruptible sleep.
      listing = """
      Ss
      R+
      D
      DN
      D<
      S<sl
      Rs
      """

      assert HostCapacity.count_d_state(listing) == 3
      assert HostCapacity.count_d_state("") == 0
    end

    test "parse_df_available_kb reads the POSIX available column" do
      output = """
      Filesystem     1024-blocks      Used Available Capacity Mounted on
      /dev/nvme0n1p1   515928144 120398112 369301488      25% /data
      """

      assert HostCapacity.parse_df_available_kb(output) == 369_301_488
      assert HostCapacity.parse_df_available_kb("") == nil
      assert HostCapacity.parse_df_available_kb("garbage\n") == nil
    end

    test "a D-state spike is unhealthy even when load and memory look fine" do
      # The 2026-08-28 shape: headcount, load and memory all healthy while
      # uninterruptible sleep climbed. The probe must not report healthy.
      snapshot = snapshot_with(d_state_reader: fn -> 224 end, max_d_state: 32)

      refute snapshot.healthy?
      assert snapshot.d_state_ok? == false
      assert snapshot.d_state_processes == 224

      assert "processes in uninterruptible sleep exceed the configured limit" in snapshot.reasons
    end

    test "a D-state probe that cannot be read is unknown, never spare capacity" do
      snapshot = snapshot_with(d_state_reader: fn -> :boom end)

      refute snapshot.available?
      assert snapshot.d_state_processes == nil
      assert "uninterruptible-sleep probe unavailable" in snapshot.reasons
    end

    test "0 disables the D-state limit" do
      snapshot = snapshot_with(d_state_reader: fn -> 500 end, max_d_state: 0)

      assert snapshot.d_state_ok?
      refute "processes in uninterruptible sleep exceed the configured limit" in snapshot.reasons
    end

    test "disk below the floor is reported and makes the host unhealthy" do
      snapshot =
        snapshot_with(
          disk_reader: fn _path -> 1_000 end,
          min_disk_available_kb: 10_485_760,
          disk_path: "/data"
        )

      refute snapshot.healthy?
      assert snapshot.disk_ok? == false
      assert snapshot.disk_available_kb == 1_000
      assert "available disk on /data is below configured minimum" in snapshot.reasons
    end

    test "ample disk is healthy and reports the path it measured" do
      snapshot =
        snapshot_with(disk_reader: fn _path -> 369_301_488 end, disk_path: "/data")

      assert snapshot.disk_ok?
      assert snapshot.disk_path == "/data"
      assert snapshot.healthy?
    end

    test "an absent disk path is not applicable, not unknown" do
      # Dev boxes and CI have no /data; that must not read as a failed probe.
      # No injected reader — this must exercise the real File.dir? check.
      snapshot = snapshot_with(disk_reader: nil, disk_path: "/definitely/not/here")

      assert snapshot.disk_available_kb == nil
      assert snapshot.disk_ok? == nil
      assert snapshot.available?
      refute Enum.any?(snapshot.reasons, &String.contains?(&1, "filesystem probe unavailable"))
    end

    test "count_agents counts a codex wrapper and its native child once" do
      listing = """
      devbox 200 1 /usr/bin/node /home/devbox/.local/bin/codex --model x
      devbox 201 200 /home/devbox/.local/lib/node_modules/@openai/codex/vendor/bin/codex --model x
      devbox 202 1 /usr/local/bin/opencode
      """

      assert HostCapacity.count_agents(listing) == 2
    end
  end

  # Healthy readings for every probe except the ones under test, so a single
  # assertion cannot pass because some unrelated probe happened to be red.
  defp snapshot_with(opts) do
    defaults = [
      load_reader: fn -> 1.0 end,
      nproc_reader: fn -> 32 end,
      mem_reader: fn -> 90_000_000 end,
      agents_reader: fn -> 1 end,
      d_state_reader: fn -> 2 end,
      disk_reader: fn _path -> 369_301_488 end,
      disk_path: "/data"
    ]

    HostCapacity.snapshot(Keyword.merge(defaults, opts))
  end
end
