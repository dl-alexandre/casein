defmodule GitCtl.Cache do
  @moduledoc false

  @default_table :casein_git_inspector_cache

  @spec table() :: atom()
  def table do
    Application.get_env(:git_ctl, :cache_table, @default_table)
  end

  @spec ttl_ms() :: non_neg_integer()
  def ttl_ms do
    Application.get_env(:git_ctl, :cache_ttl_ms, 10_000)
  end

  @spec lookup(String.t(), non_neg_integer()) :: {:ok, term()} | :miss
  def lookup(cwd, ttl) when is_binary(cwd) and is_integer(ttl) and ttl > 0 do
    case :ets.lookup(table(), cwd) do
      [{^cwd, result, inserted_at}] ->
        if System.monotonic_time(:millisecond) - inserted_at <= ttl do
          {:ok, result}
        else
          :miss
        end

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  def lookup(_, _), do: :miss

  @spec store(String.t(), term()) :: :ok
  def store(cwd, result) when is_binary(cwd) do
    :ets.insert(table(), {cwd, result, System.monotonic_time(:millisecond)})
    :ok
  rescue
    ArgumentError -> :ok
  end
end
