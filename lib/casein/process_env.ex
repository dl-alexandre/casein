defmodule Casein.ProcessEnv do
  @moduledoc """
  Process-scoped overrides for `Application` config keys, with `$callers`
  propagation.

  A test can override a swappable-adapter key for its own process — and any
  process it spawns via `Task`/`GenServer`, which record the spawning pid in
  the `$callers` chain — without mutating global `Application` env. Because the
  override lives in the process dictionary rather than a global, the test that
  sets it can run `async: true` alongside tests that resolve the same key to a
  different value.

  Production code reads a swappable adapter through `get/3` instead of
  `Application.get_env/3`. When no override is set (the production path), it is
  a thin wrapper over `Application.get_env/3`; the only extra work is a cheap
  process-dictionary read on the calling process, plus — for the rare process
  that carries a non-empty `$callers` chain — a lookup on those pids.

  ## Resolution order (`get/3`)

    1. an override on the calling process
    2. an override on any pid in the caller's `$callers` chain
    3. `Application.get_env(app, key, default)`

  ## Example

      # in a test running `async: true`
      Casein.ProcessEnv.put(:git_adapter, MyStubAdapter)

      # in production code
      defp impl, do: Casein.ProcessEnv.get(:casein, :git_adapter, Casein.Git.LocalAdapter)
  """

  @absent :"$casein_process_env_absent"

  @doc """
  Resolve `key`, preferring a process-scoped override and falling back to
  `Application.get_env(app, key, default)`.
  """
  @spec get(atom(), atom(), term()) :: term()
  def get(app, key, default) do
    case fetch(key) do
      {:ok, value} -> value
      :error -> Application.get_env(app, key, default)
    end
  end

  @doc """
  Set a process-scoped override for `key`, visible to this process and any it
  spawns through the `$callers` chain.
  """
  @spec put(atom(), term()) :: :ok
  def put(key, value) do
    Process.put(pkey(key), value)
    :ok
  end

  @doc "Remove a process-scoped override previously set with `put/2`."
  @spec delete(atom()) :: :ok
  def delete(key) do
    Process.delete(pkey(key))
    :ok
  end

  defp fetch(key) do
    case Process.get(pkey(key), @absent) do
      @absent -> fetch_from_callers(key)
      value -> {:ok, value}
    end
  end

  defp fetch_from_callers(key) do
    :"$callers"
    |> Process.get([])
    |> Enum.reduce_while(:error, fn pid, _acc ->
      case remote_override(pid, key) do
        {:ok, _} = ok -> {:halt, ok}
        :error -> {:cont, :error}
      end
    end)
  end

  defp remote_override(pid, key) do
    with {:dictionary, dict} when is_list(dict) <- Process.info(pid, :dictionary),
         {_, value} <- List.keyfind(dict, pkey(key), 0) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  defp pkey(key), do: {__MODULE__, key}
end
