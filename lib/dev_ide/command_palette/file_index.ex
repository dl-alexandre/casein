defmodule DevIDE.CommandPalette.FileIndex do
  @moduledoc """
  Workspace-rooted file walker for the command palette.

  Capped at 5_000 files. Ignored dirs come from
  `DevIDE.Files.PathSafety.ignored_dir?/1` so the palette honours the same
  allowlist as the file tree. Symlinks are not followed.

  Results are cached per expanded root in a public ETS table (`:dev_ide_file_index_cache`)
  with a short TTL so palette keystrokes do not re-walk the tree. Call
  `invalidate/1` after a file-tree refresh (or any mutation that changes listing).
  """

  alias DevIDE.Files.PathSafety

  @table :dev_ide_file_index_cache
  @file_cap 5_000
  @ttl_ms 30_000

  @spec list(String.t()) :: [String.t()]
  def list(root) when is_binary(root) do
    abs_root = Path.expand(root)

    if File.dir?(abs_root) do
      cached_list(abs_root)
    else
      []
    end
  end

  def list(_), do: []

  @doc "Drop the cached listing for `root` so the next `list/1` re-walks."
  @spec invalidate(String.t()) :: :ok
  def invalidate(root) when is_binary(root) do
    if table_ready?(), do: :ets.delete(@table, Path.expand(root))
    :ok
  end

  def invalidate(_), do: :ok

  @doc false
  def ttl_ms, do: @ttl_ms

  defp cached_list(abs_root) do
    now = System.monotonic_time(:millisecond)

    case cache_lookup(abs_root, now) do
      {:hit, files} ->
        files

      :miss ->
        files = scan(abs_root)
        cache_store(abs_root, files, now + @ttl_ms)
        files
    end
  end

  defp cache_lookup(abs_root, now) do
    with true <- table_ready?(),
         [{^abs_root, files, expires_at}] <- :ets.lookup(@table, abs_root),
         true <- expires_at > now do
      {:hit, files}
    else
      _ -> :miss
    end
  end

  defp cache_store(abs_root, files, expires_at) do
    ensure_cache_table()
    :ets.insert(@table, {abs_root, files, expires_at})
  end

  defp scan(abs_root) do
    walk(abs_root, abs_root, [], 0)
    |> elem(0)
    |> Enum.reverse()
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

  defp ensure_cache_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        catch
          :error, :badarg -> :ok
        end

      _ ->
        :ok
    end
  end

  defp table_ready?, do: :ets.whereis(@table) != :undefined

  def cap, do: @file_cap
end
