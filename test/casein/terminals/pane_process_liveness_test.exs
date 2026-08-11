defmodule Casein.Terminals.PaneProcessLivenessTest do
  # Mutates Application env for the process-liveness ETS table name.
  use ExUnit.Case, async: false

  alias Casein.Terminals.PaneProcessLiveness

  setup do
    table = :"pane_proc_live_#{System.unique_integer([:positive])}"
    previous = Application.get_env(:casein, :pane_process_liveness_cache_table)
    Application.put_env(:casein, :pane_process_liveness_cache_table, table)
    on_exit(fn -> Application.put_env(:casein, :pane_process_liveness_cache_table, previous) end)
    PaneProcessLiveness.ensure_cache_table()
    :ok
  end

  defp seed_opts(seeds, stats, now_ms, extra \\ []) do
    [
      now_ms: now_ms,
      pid_reader: fn _session -> seeds end,
      stat_reader: fn pid ->
        case Map.fetch(stats, pid) do
          {:ok, j} -> {:ok, j}
          :error -> :error
        end
      end,
      children_reader: fn _pid -> [] end,
      quiet_after_ms: 1_000
    ] ++ extra
  end

  test "runtime_from_command classifies known agent binaries" do
    assert PaneProcessLiveness.runtime_from_command("opencode") == "opencode"
    assert PaneProcessLiveness.runtime_from_command("/usr/bin/claude") == "claude"
    assert PaneProcessLiveness.runtime_from_command("bash") == "shell"
    assert PaneProcessLiveness.runtime_from_command(nil) == nil
  end

  test "first sample is unknown/warming and seeds the cache — not quiet" do
    seeds = %{"%1" => %{pid: 111, current_command: "opencode"}}
    stats = %{111 => 40}

    obs =
      PaneProcessLiveness.observe_session("sess", seed_opts(seeds, stats, 1_000))

    assert obs["%1"].state == :unknown
    assert obs["%1"].reason == :warming
    assert obs["%1"].runtime == "opencode"
    assert obs["%1"].cpu_jiffies == 40
    assert obs["%1"].pid == 111
  end

  test "advancing CPU jiffies reports active even when a screen would look frozen" do
    seeds = %{"%1" => %{pid: 222, current_command: "opencode"}}

    _ =
      PaneProcessLiveness.observe_session(
        "sess",
        seed_opts(seeds, %{222 => 100}, 1_000)
      )

    obs =
      PaneProcessLiveness.observe_session(
        "sess",
        seed_opts(seeds, %{222 => 250}, 2_000)
      )

    assert obs["%1"].state == :active
    assert obs["%1"].cpu_jiffies_delta == 150
    assert obs["%1"].reason == nil
  end

  test "stalled CPU after quiet_after_ms is quiet — not spinner-based" do
    seeds = %{"%1" => %{pid: 333, current_command: "claude"}}

    _ =
      PaneProcessLiveness.observe_session(
        "sess",
        seed_opts(seeds, %{333 => 50}, 1_000)
      )

    # Second sample soon: still settling / not yet quiet
    mid =
      PaneProcessLiveness.observe_session(
        "sess",
        seed_opts(seeds, %{333 => 50}, 1_500)
      )

    assert mid["%1"].state in [:unknown, :active]
    refute mid["%1"].state == :quiet

    quiet =
      PaneProcessLiveness.observe_session(
        "sess",
        seed_opts(seeds, %{333 => 50}, 3_000)
      )

    assert quiet["%1"].state == :quiet
    assert quiet["%1"].reason == :cpu_stalled
    assert quiet["%1"].cpu_jiffies_delta == 0
  end

  test "missing proc entry is unknown with reason, never quiet" do
    seeds = %{"%9" => %{pid: 999, current_command: "opencode"}}

    obs =
      PaneProcessLiveness.observe_session(
        "sess",
        seed_opts(seeds, %{}, 1_000)
      )

    # empty children + missing stat → tree empty → proc_missing
    assert obs["%9"].state == :unknown
    assert obs["%9"].reason == :proc_missing
  end

  test "no pane_pid is unknown/no_pid" do
    seeds = %{"%2" => %{pid: nil, current_command: "bash"}}

    obs =
      PaneProcessLiveness.observe_session(
        "sess",
        seed_opts(seeds, %{}, 1_000)
      )

    assert obs["%2"].state == :unknown
    assert obs["%2"].reason == :no_pid
  end
end
