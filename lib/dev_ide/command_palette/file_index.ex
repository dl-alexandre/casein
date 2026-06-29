defmodule DevIDE.CommandPalette.FileIndex do
  @moduledoc """
  Workspace-rooted file walker for the command palette.

  Capped at 5_000 files. Ignored dirs come from
  `DevIDE.Files.PathSafety.ignored_dir?/1` so the palette honours the same
  allowlist as the file tree. Symlinks are not followed.
  """

  alias DevIDE.Files.PathSafety

  @file_cap 5_000

  @spec list(String.t()) :: [String.t()]
  def list(root) when is_binary(root) do
    abs_root = Path.expand(root)

    if File.dir?(abs_root) do
      walk(abs_root, abs_root, [], 0)
      |> elem(0)
      |> Enum.reverse()
    else
      []
    end
  end

  def list(_), do: []

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
