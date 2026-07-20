defmodule DevIDE.Files.PathSafety do
  use Boundary, top_level?: true, deps: [], exports: []

  @moduledoc """
  Workspace path safety primitives.

  Two layers:
    1. Allowlist: a target path must canonicalise inside a workspace root.
    2. Ignore set: dirs and files that are noisy or dangerous to surface
       (`.git`, `_build`, `deps`, `node_modules`, `priv/static/cache`).

  Resolution uses `Path.expand/1` and rejects symlinks that escape the
  workspace root. Symlink detection uses `File.lstat/1` so a symlink to
  outside is refused even if its target lies inside.
  """

  @ignored_dirs ~w(.git .hg .svn _build deps node_modules .elixir_ls .lexical .DS_Store)
  @ignored_globs ~w(priv/static/cache priv/static/assets/cache)

  @max_relative_segments 32

  @type reason :: :outside_root | :symlink_escape | :too_deep | :missing_path

  @doc """
  Resolve `relative` against `root` and return `{:ok, abs_path}` if the
  result is inside `root` and not a symlink leaving the root, else
  `{:error, reason}`.
  """
  @spec resolve(String.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  def resolve(root, relative) when is_binary(root) and is_binary(relative) do
    root_abs = Path.expand(root)
    target = Path.expand(relative, root_abs)

    cond do
      depth(relative) > @max_relative_segments -> {:error, :too_deep}
      not under?(target, root_abs) -> {:error, :outside_root}
      symlink_escapes?(target, root_abs) -> {:error, :symlink_escape}
      true -> {:ok, target}
    end
  end

  def resolve(_, _), do: {:error, :missing_path}

  @doc "Is the basename in the global ignore set?"
  def ignored_dir?(name), do: name in @ignored_dirs

  @doc "Is `relative` inside any ignored glob (e.g. priv/static/cache)?"
  def ignored_path?(relative) when is_binary(relative) do
    rel = String.trim_leading(relative, "/")
    Enum.any?(@ignored_globs, fn g -> rel == g or String.starts_with?(rel, g <> "/") end)
  end

  @doc "Reject obviously-binary content via NUL-byte sniff in the first 8 KB."
  def likely_binary?(bin) when is_binary(bin) do
    head = binary_part(bin, 0, min(byte_size(bin), 8192))
    String.contains?(head, <<0>>)
  end

  defp depth(rel), do: rel |> Path.split() |> Enum.count(&(&1 not in [".", "/"]))

  defp under?(path, root) do
    rel = Path.relative_to(path, root)
    rel != path and not String.starts_with?(rel, "..")
  end

  defp symlink_escapes?(path, root) do
    # Walk each segment; if any prefix is a symlink whose resolved target
    # is outside the root, refuse. Then resolve the complete chain as well:
    # an in-root link may point at another in-root link that escapes.
    immediate_escape? =
      path
      |> ancestors_within(root)
      |> Enum.any?(fn p ->
        case File.lstat(p) do
          {:ok, %File.Stat{type: :symlink}} ->
            case File.read_link(p) do
              {:ok, link} ->
                resolved = Path.expand(link, Path.dirname(p))
                not under?(resolved, root)

              _ ->
                true
            end

          _ ->
            false
        end
      end)

    immediate_escape? or canonical_path_escapes?(path, root)
  end

  defp canonical_path_escapes?(path, root) do
    with {:ok, canonical_root} <- canonicalize(root),
         {:ok, canonical_path} <- canonicalize(path) do
      not under?(canonical_path, canonical_root)
    else
      _ -> true
    end
  end

  # Resolve links segment-by-segment and restart from their target so chained
  # links are followed. Missing suffixes are safe to retain once their nearest
  # existing ancestor has been canonicalised.
  defp canonicalize(path) do
    [root | segments] = path |> Path.expand() |> Path.split()
    resolve_segments(root, segments, 0)
  end

  defp resolve_segments(path, [], _links), do: {:ok, Path.expand(path)}
  defp resolve_segments(_path, _segments, links) when links > 40, do: {:error, :eloop}

  defp resolve_segments(path, [segment | rest], links) do
    candidate = Path.join(path, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, link} <- File.read_link(candidate) do
          [root | target_segments] = link |> Path.expand(path) |> Path.split()
          resolve_segments(root, target_segments ++ rest, links + 1)
        end

      {:ok, _stat} ->
        resolve_segments(candidate, rest, links)

      {:error, :enoent} ->
        {:ok, Path.join([candidate | rest]) |> Path.expand()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ancestors_within(path, root) do
    Stream.unfold(path, fn
      ^root -> nil
      p when p == "/" -> nil
      p -> {p, Path.dirname(p)}
    end)
    |> Enum.to_list()
  end
end
