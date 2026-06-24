defmodule DevIDE.Previews.Storage.LocalDisk do
  @moduledoc """
  Disk-backed `DevIDE.Previews.Storage`.

  Writes one servable file per artifact at `{root}/{workspace_id}/{id}.{ext}` and
  prunes each workspace directory to the most recent `:preview_max_artifacts`
  files. The displayed pane always points at the newest artifact, so older ones
  are stale and safe to drop. Owns all on-disk path logic (root, prune, safe
  resolution) so `DevIDE.Previews.Artifacts` can stay a thin facade.
  """

  @behaviour DevIDE.Previews.Storage

  @default_max_artifacts 50

  @impl true
  def put(workspace_id, id, ext, source)
      when is_binary(workspace_id) and is_binary(id) and is_binary(ext) do
    dir = Path.join([artifacts_root(), workspace_id])
    File.mkdir_p!(dir)

    filename = "#{id}.#{ext}"
    path = Path.join(dir, filename)

    case write_source(path, source) do
      :ok ->
        prune_dir(dir, max_artifacts())
        {:ok, "/preview-artifacts/#{workspace_id}/#{filename}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_source(path, {:bytes, bytes}) when is_binary(bytes), do: File.write(path, bytes)
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
  # never fail because cleanup of older snapshots failed.
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
