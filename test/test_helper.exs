# `:pty` tests attach real tmux PTYs and assert genuine PTY/owner-sharing
# invariants. They are reliable only on a PTY-stable host (e.g. devbox) and
# flake under load in sandboxes/CI. Excluded by default; run them explicitly
# where PTY is stable with: mix test --include pty
#
# Keep concurrency below PostgreSQL's per-container connection ceiling. The
# default max_cases (scheduler count; 64 in this devbox) can temporarily open
# enough sandbox connections to hit FATAL 53300 "too many clients already",
# which makes otherwise-valid full-suite/precommit runs flaky.
ExUnit.start(exclude: [:pty], max_cases: 8)

unless System.get_env("MIX_TEST_NO_START") in ["1", "true"] do
  {:ok, _} = Application.ensure_all_started(:dev_ide)
end

# When run with `--no-start` (e.g. for pure unit tests under memory pressure),
# the Repo isn't running — skip sandbox setup rather than crash on boot.
if Process.whereis(DevIde.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(DevIde.Repo, :manual)
end
