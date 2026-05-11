defmodule DevIDE.Files.PathSafety do
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
    # is outside the root, refuse.
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
