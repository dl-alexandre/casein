# `:pty` tests attach real tmux PTYs and assert genuine PTY/owner-sharing
# invariants. They are reliable only on a PTY-stable host (e.g. devbox) and
# flake under load in sandboxes/CI. Excluded by default; run them explicitly
# where PTY is stable with: mix test --include pty
ExUnit.start(exclude: [:pty])

# When run with `--no-start` (e.g. for pure unit tests under memory pressure),
# the Repo isn't running — skip sandbox setup rather than crash on boot.
if Process.whereis(DevIde.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(DevIde.Repo, :manual)
end
