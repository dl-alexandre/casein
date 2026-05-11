defmodule DevIDE.Proposals.LocalAdapter do
  @moduledoc """
  Filesystem discovery + parsing of proposal artifacts. Read-only.

  Discovery roots are workspace-relative and run through `PathSafety.resolve/2`
  so traversal/symlink-escape can't reach disk through this adapter. Files are
  size-capped before reading, and parsing is bounded to unified-diff header
  extraction — no patch application code path exists.
  """

  @behaviour DevIDE.Proposals

  alias DevIDE.Files.PathSafety
  alias DevIDE.Proposals.{Proposal, UnifiedDiff}

  @discovery_dirs [
    ".opencode/proposals",
    ".opencode/sessions",
    ".opencode/logs",
    ".agent/proposals"
  ]

  @max_file_bytes 512 * 1024
  @max_diff_render 256 * 1024
  @max_results 20

  @impl true
  def discover(root) when is_binary(root) do
    @discovery_dirs
    |> Enum.flat_map(&list_dir(root, &1))
    |> Enum.sort_by(& &1.mtime, {:desc, NaiveDateTime})
    |> Enum.take(@max_results)
  end

  @impl true
  def parse(root, rel_path) when is_binary(root) and is_binary(rel_path) do
    with {:ok, abs} <- PathSafety.resolve(root, rel_path),
         true <- supported?(rel_path) || {:error, :unsupported},
         {:ok, %File.Stat{type: :regular, size: size, mtime: mt}} <- File.stat(abs),
         true <- size <= @max_file_bytes || {:error, :too_large},
         {:ok, content} <- File.read(abs) do
      {parser, status, changes, diff, truncated, error} = parse_content(content, root)

      {:ok,
       %Proposal{
         rel_path: rel_path,
         name: Path.basename(rel_path),
         size: size,
         mtime: erl_to_naive(mt),
         parser: parser,
         status: status,
         changes: changes,
         diff: diff,
         truncated: truncated,
         error: error
       }}
    else
      {:error, :unsupported} -> proposal_error(rel_path, :unsupported)
      {:error, :too_large} -> proposal_error(rel_path, :too_large)
      {:ok, %File.Stat{}} -> proposal_error(rel_path, :invalid)
      {:error, reason} -> proposal_error(rel_path, :invalid, inspect(reason))
    end
  end

  ## Helpers

  defp list_dir(root, rel) do
    with {:ok, abs} <- PathSafety.resolve(root, rel),
         {:ok, %File.Stat{type: :directory}} <- File.stat(abs),
         {:ok, names} <- File.ls(abs) do
      Enum.flat_map(names, fn name -> stat_file(abs, rel, name) end)
    else
      _ -> []
    end
  end

  defp stat_file(abs, rel, name) do
    if supported?(name) do
      full = Path.join(abs, name)

      case File.lstat(full) do
        {:ok, %File.Stat{type: :regular, size: size, mtime: mt}} ->
          [
            %Proposal{
              rel_path: Path.join(rel, name),
              name: name,
              size: size,
              mtime: erl_to_naive(mt),
              parser: parser_for(name),
              status: if(size > @max_file_bytes, do: :too_large, else: :unsupported)
            }
          ]

        _ ->
          []
      end
    else
      []
    end
  end

  defp supported?(name) do
    ext = name |> String.downcase() |> Path.extname()
    ext in [".diff", ".patch"]
  end

  defp parser_for(name) do
    if supported?(name), do: :unified_diff, else: :unsupported
  end

  defp parse_content(content, root) do
    diff_render =
      if byte_size(content) > @max_diff_render do
        head = binary_part(content, 0, @max_diff_render)
        head <> "\n... [truncated]"
      else
        content
      end

    truncated = byte_size(content) > @max_diff_render

    case UnifiedDiff.parse(content, root) do
      {:ok, changes} ->
        {:unified_diff, :parsed, changes, diff_render, truncated, nil}

      {:error, :invalid_path} ->
        {:unified_diff, :invalid, [], diff_render, truncated, "path traversal in diff header"}

      {:error, :no_headers} ->
        {:unified_diff, :invalid, [], diff_render, truncated, "no unified diff headers found"}
    end
  end

  defp proposal_error(rel_path, status, error \\ nil) do
    {:ok,
     %Proposal{
       rel_path: rel_path,
       name: Path.basename(rel_path),
       parser: parser_for(rel_path),
       status: status,
       error: error
     }}
  end

  defp erl_to_naive({{y, mo, d}, {h, mi, s}}) do
    case NaiveDateTime.new(y, mo, d, h, mi, s) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp erl_to_naive(_), do: nil
end
