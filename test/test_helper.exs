ExUnit.start()

# When run with `--no-start` (e.g. for pure unit tests under memory pressure),
# the Repo isn't running — skip sandbox setup rather than crash on boot.
if Process.whereis(DevIde.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(DevIde.Repo, :manual)
end
