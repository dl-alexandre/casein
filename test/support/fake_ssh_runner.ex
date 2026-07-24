defmodule Casein.Test.FakeSshRunner do
  @moduledoc """
  Test `SshRunner` that replays canned responses. Each test registers a
  handler via `set/1` / `set_stdin/1`.

  Handlers are stored in an ETS table keyed by the owning test pid, so they
  survive being read from a `Task.async`-spawned process (the code under test
  runs ssh inside a Task for timeouts). The fake resolves the owning test by
  walking `:"$callers"` — the chain ExUnit + Task propagate.
  """

  @behaviour Casein.Workspaces.SshRunner

  @table :fake_ssh_runner_handlers

  defp table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      tid -> tid
    end
  end

  def set(fun) when is_function(fun, 2) do
    :ets.insert(table(), {{self(), :run}, fun})
    :ok
  end

  def set_stdin(fun) when is_function(fun, 3) do
    :ets.insert(table(), {{self(), :stdin}, fun})
    :ok
  end

  @impl true
  def run(host, argv) do
    case lookup(:run) do
      fun when is_function(fun, 2) -> fun.(host, argv)
      nil -> {:error, :no_fake_handler_set}
    end
  end

  @impl true
  def run_with_stdin(host, argv, stdin) do
    case lookup(:stdin) do
      fun when is_function(fun, 3) -> fun.(host, argv, stdin)
      nil -> :ok
    end
  end

  # Resolve the owning test pid: self() first, then each entry in the
  # $callers chain that Task.async propagates.
  defp lookup(kind) do
    pids = [self() | Process.get(:"$callers", [])]

    Enum.find_value(pids, fn pid ->
      case :ets.lookup(table(), {pid, kind}) do
        [{_, fun}] -> fun
        [] -> nil
      end
    end)
  end
end
