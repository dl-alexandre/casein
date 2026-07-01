defmodule DevIDE.Previews.Storage.LocalDisk do
  @moduledoc """
  Disk-backed `DevIDE.Previews.Storage`.

  Writes one servable file per artifact at `{root}/{workspace_id}/{id}.{ext}` and
  prunes each workspace directory to the most recent `:preview_max_artifacts`
  files. Screenshot PNGs and visual-diff overlays (`*-diff.png`) share the same
  workspace directory and prune budget, so a diff-heavy agent loop can evict a
  screenshot a pane is still displaying. The displayed pane always points at the
  newest artifact, so older ones are stale and safe to drop. Owns all on-disk
  path logic (root, prune, safe resolution) so `DevIDE.Previews.Artifacts` can
  stay a thin facade.
  """

  @behaviour DevIDE.Previews.Storage

  @default_max_artifacts 50

  # Components are validated by validate_component/1 and the resolved target is
  # confirmed under artifacts_root before any write.
  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def put(workspace_id, id, ext, source)
      when is_binary(workspace_id) and is_binary(id) and is_binary(ext) do
    with :ok <- validate_component(workspace_id),
         :ok <- validate_component(id),
         :ok <- validate_component(ext) do
      dir = Path.join([artifacts_root(), workspace_id])
      filename = "#{id}.#{ext}"
      path = Path.join(dir, filename)

      # Defense in depth: the component checks already forbid traversal, but
      # confirm the resolved write target stays under the artifacts root before
      # touching the filesystem.
      if String.starts_with?(Path.expand(path), Path.expand(artifacts_root()) <> "/") do
        File.mkdir_p!(dir)

        case write_source(path, source) do
          :ok ->
            prune_dir(dir, max_artifacts())
            {:ok, "/preview-artifacts/#{workspace_id}/#{filename}"}

          {:error, reason} ->
            {:error, reason}
        end
      else
        {:error, :invalid_path}
      end
    end
  end

  # Each artifact path is `{root}/{workspace_id}/{id}.{ext}`, so a caller-supplied
  # component must be a single traversal-free segment — a separator or `..` could
  # otherwise escape the artifacts root. Mirrors the `safe_path!/2` read guard.
  defp validate_component(component) do
    if component == Path.basename(component) and component not in ["", ".", ".."] and
         not String.contains?(component, ["/", "\\", ".."]) do
      :ok
    else
      {:error, :invalid_path}
    end
  end

  # path is built only from components already validated in put/4.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_source(path, {:bytes, bytes}) when is_binary(bytes), do: File.write(path, bytes)

  # path is built only from components already validated in put/4.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_source(path, {:file, src}) when is_binary(src), do: File.cp(src, path)
  defp write_source(_path, _source), do: {:error, :invalid_source}

  @doc """
  Resolve an artifact path under the artifacts root, rejecting traversal.

  Raises on an invalid filename or a missing file so callers can rescue into a
  404, matching the previous `DevIDE.Previews.Artifacts.safe_path!/2` contract.
  """
  @spec safe_path!(String.t(), String.t()) :: Path.t()
  def safe_path!(workspace_id, filename) when is_binary(workspace_id) and is_binary(filename) do
    if filename != Path.basename(filename) or String.contains?(filename, "..") do
      raise ArgumentError, "invalid artifact filename"
    end

    path = Path.join([artifacts_root(), workspace_id, filename])
    root = Path.expand(artifacts_root())

    if String.starts_with?(Path.expand(path), root <> "/") and File.exists?(path) do
      path
    else
      raise File.Error, reason: :enoent, action: "read", path: path
    end
  end

  # Keep only the newest `max` artifacts in `dir`. Best-effort: a capture must
  # never fail because cleanup of older snapshots failed. dir comes from put/4's
  # validated workspace_id; entries are read back from File.ls of that dir.
  # sobelow_skip ["Traversal.FileModule"]
  defp prune_dir(dir, max) when is_integer(max) and max > 0 do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&{&1, file_mtime(&1)})
        |> Enum.sort_by(fn {_path, mtime} -> mtime end, :desc)
        |> Enum.drop(max)
        |> Enum.each(fn {path, _mtime} -> _ = File.rm(path) end)

      _ ->
        :ok
    end
  end

  defp prune_dir(_dir, _max), do: :ok

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      _ -> 0
    end
  end

  defp max_artifacts do
    Application.get_env(:dev_ide, :preview_max_artifacts, @default_max_artifacts)
  end

  @doc "Filesystem root for preview artifacts."
  @spec artifacts_root() :: Path.t()
  def artifacts_root do
    Application.get_env(:dev_ide, :preview_artifacts_root) ||
      Path.join([File.cwd!(), "priv", "preview_artifacts"])
  end
end
