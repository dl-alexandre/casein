defmodule Casein.Previews.Storage.LocalDisk do
  @moduledoc """
  Disk-backed `Casein.Previews.Storage`.

  Writes one servable file per artifact at `{root}/{workspace_id}/{id}.{ext}` and
  prunes each workspace directory with separate budgets for screenshot captures
  and visual-diff overlays (`*-diff.png`). Filenames registered with
  `Casein.Previews.ArtifactProtection` are never pruned while displayed.
  """

  @behaviour Casein.Previews.Storage

  alias Casein.Previews.ArtifactProtection

  @default_max_artifacts 50
  @default_max_diff_artifacts 100

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
            prune_dir(dir, workspace_id, filename)
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
  404, matching the previous `Casein.Previews.Artifacts.safe_path!/2` contract.
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

  defp prune_dir(dir, workspace_id, just_written) do
    case File.ls(dir) do
      {:ok, entries} ->
        protected = protected_basenames(workspace_id)

        entries
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.regular?/1)
        |> Enum.split_with(&diff_artifact?/1)
        |> then(fn {diffs, captures} ->
          prune_bucket(diffs, max_diff_artifacts(), protected, just_written)
          prune_bucket(captures, max_screenshot_artifacts(), protected, just_written)
        end)

      _ ->
        :ok
    end
  end

  # paths come from File.ls/1 inside the validated artifact directory.
  # sobelow_skip ["Traversal.FileModule"]
  defp prune_bucket(paths, max, protected, just_written) when is_integer(max) and max > 0 do
    paths
    |> Enum.reject(&(Path.basename(&1) in protected))
    # mtime has one-second granularity, so a burst of writes ties; rank the
    # just-written artifact above its tie so put/4 never deletes the file whose
    # URL it is about to return.
    |> Enum.map(&{&1, {file_mtime(&1), Path.basename(&1) == just_written}})
    |> Enum.sort_by(fn {_path, rank} -> rank end, :desc)
    |> Enum.drop(max)
    |> Enum.each(fn {path, _rank} -> _ = File.rm(path) end)

    :ok
  end

  defp prune_bucket(_paths, _max, _protected, _just_written), do: :ok

  defp diff_artifact?(path) do
    basename = Path.basename(path)
    String.ends_with?(basename, "-diff.png")
  end

  defp protected_basenames(workspace_id) do
    workspace_id
    |> ArtifactProtection.protected()
    |> MapSet.to_list()
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      _ -> 0
    end
  end

  defp max_screenshot_artifacts do
    Application.get_env(:casein, :preview_max_artifacts, @default_max_artifacts)
  end

  defp max_diff_artifacts do
    Application.get_env(:casein, :preview_max_diff_artifacts, @default_max_diff_artifacts)
  end

  @doc "Filesystem root for preview artifacts."
  @spec artifacts_root() :: Path.t()
  def artifacts_root do
    Application.get_env(:casein, :preview_artifacts_root) ||
      Path.join([File.cwd!(), "priv", "preview_artifacts"])
  end
end
