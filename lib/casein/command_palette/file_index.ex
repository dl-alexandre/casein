defmodule Casein.CommandPalette.FileIndex do
  @moduledoc """
  Workspace-rooted file walker for the command palette.

  Capped at 5_000 files. Ignored dirs come from
  `Casein.Files.PathSafety.ignored_dir?/1` so the palette honours the same
  allowlist as the file tree. Symlinks are not followed.
  """

  alias Casein.Files.PathSafety

  @file_cap 5_000

  @table :casein_palette_file_index_cache
  @ttl_ms 2_000

  @doc false
  def ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        access = Application.get_env(:casein, :ets_table_access, :protected)

        :ets.new(@table, [
          :named_table,
          access,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        :ok
    end
  end

  @doc """
  Relative paths under `root`, memoized for #{@ttl_ms}ms.

  The palette re-queries on every keystroke, and each uncapped walk costs a
  `File.ls/1` per directory plus a `File.lstat/1` per entry (up to #{@file_cap}
  files) *synchronously on the LiveView process* — which also stalls queued
  terminal frames. The TTL collapses a typing burst onto one walk while staying
  short enough that newly created files still surface promptly.
  """
  @spec list(String.t()) :: [String.t()]
  def list(root) when is_binary(root) do
    abs_root = Path.expand(root)
    now = System.monotonic_time(:millisecond)

    case cached(abs_root, now) do
      {:ok, paths} -> paths
      :miss -> abs_root |> walk_root() |> cache(abs_root, now)
    end
  end

  def list(_), do: []

  defp walk_root(abs_root) do
    if File.dir?(abs_root) do
      walk(abs_root, abs_root, [], 0)
      |> elem(0)
      |> Enum.reverse()
    else
      []
    end
  end

  defp cached(abs_root, now) do
    ensure_table!()

    case :ets.lookup(@table, abs_root) do
      [{^abs_root, paths, expires_at}] when expires_at > now -> {:ok, paths}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache(paths, abs_root, now) do
    :ets.insert(@table, {abs_root, paths, now + @ttl_ms})
    paths
  rescue
    ArgumentError -> paths
  end

  defp walk(_root, _dir, acc, count) when count >= @file_cap, do: {acc, count}

  defp walk(root, dir, acc, count) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce_while(names, {acc, count}, fn name, {acc, count} ->
          if count >= @file_cap or PathSafety.ignored_dir?(name) do
            {:cont, {acc, count}}
          else
            full = Path.join(dir, name)
            handle(root, full, name, acc, count)
          end
        end)

      _ ->
        {acc, count}
    end
  end

  defp handle(root, full, name, acc, count) do
    case File.lstat(full) do
      {:ok, %File.Stat{type: :regular}} ->
        rel = Path.relative_to(full, root)

        if PathSafety.ignored_path?(rel) do
          {:cont, {acc, count}}
        else
          {:cont, {[rel | acc], count + 1}}
        end

      {:ok, %File.Stat{type: :directory}} ->
        if String.starts_with?(name, ".") and not surface_dot_dir?(name) do
          {:cont, {acc, count}}
        else
          {acc, count} = walk(root, full, acc, count)
          {:cont, {acc, count}}
        end

      _ ->
        # symlink / fifo / other — skip
        {:cont, {acc, count}}
    end
  end

  defp surface_dot_dir?(".formatter"), do: true
  defp surface_dot_dir?(".github"), do: true
  defp surface_dot_dir?(_), do: false

  def cap, do: @file_cap
end
