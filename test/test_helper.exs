# `:pty` tests attach real tmux PTYs and assert genuine PTY/owner-sharing
# invariants. They are reliable only on a PTY-stable host (e.g. devbox) and
# flake under load in sandboxes/CI. Excluded by default; run them explicitly
# where PTY is stable with: mix test --include pty
#
# Keep concurrency below PostgreSQL's per-container connection ceiling. The
# default max_cases (scheduler count; 64 in this devbox) can temporarily open
# enough sandbox connections to hit FATAL 53300 "too many clients already",
# which makes otherwise-valid full-suite/precommit runs flaky.
# assert_receive defaults to 100ms, which flakes under full-suite CPU contention
# on this multi-tenant box: tests that drive a LiveView event → fake adapter →
# message round-trip (e.g. the `{:fake_tmux_*}` pane-split assertions) usually
# complete in <100ms in isolation but occasionally miss the window under load,
# failing a different subtest each run. Raising the global grace to 1s costs
# passing tests nothing (assert_receive returns as soon as the message lands)
# and only extends the wait before a genuine failure. refute_receive keeps its
# own (short, explicit) timeouts, so negative assertions are unaffected.
ExUnit.start(exclude: [:pty, :tidewave_available], max_cases: 8, assert_receive_timeout: 1_000)

# Drain tests arm real grace/hard timeouts on the singleton Drain server;
# without this seam the timer fires ~3s later and System.stop(0) gracefully
# shuts down the VM MID-SUITE — silently truncated runs that still exit 0.
# (Root-caused 2026-06-12 after a day of "tests truncate under load".)
Application.put_env(:dev_ide, :drain_stop_system, fn _status ->
  IO.puts(:stderr, "[test] Drain stop_system intercepted (would have stopped the VM)")
  :ok
end)

unless System.get_env("MIX_TEST_NO_START") in ["1", "true"] do
  {:ok, _} = Application.ensure_all_started(:dev_ide)
end

# When run with `--no-start` (e.g. for pure unit tests under memory pressure),
# the Repo isn't running — skip sandbox setup rather than crash on boot.
if Process.whereis(DevIde.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(DevIde.Repo, :manual)
end
