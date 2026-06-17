defmodule DevIDE.Previews.Artifacts do
  @moduledoc """
  Persists preview screenshot artifacts to servable static paths.

  Each capture writes one PNG and nothing else removes them, so writes prune the
  workspace's artifact directory down to the most recent `:preview_max_artifacts`
  files. The displayed pane always points at the newest artifact, so older ones
  are stale and safe to drop.
  """

  @default_max_artifacts 50

  @doc "Store PNG bytes and return a browser-servable path."
  @spec store_png!(String.t(), integer(), binary()) :: String.t()
  def store_png!(workspace_id, observation_id, png_bytes)
      when is_binary(workspace_id) and is_integer(observation_id) and is_binary(png_bytes) do
    dir = Path.join([artifacts_root(), workspace_id])
    File.mkdir_p!(dir)

    filename = "#{observation_id}.png"
    path = Path.join(dir, filename)
    File.write!(path, png_bytes)
    prune_dir(dir, max_artifacts())
    "/preview-artifacts/#{workspace_id}/#{filename}"
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

  @doc "Resolve artifact path under the artifacts root."
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

  defp artifacts_root do
    Application.get_env(:dev_ide, :preview_artifacts_root) ||
      Path.join([File.cwd!(), "priv", "preview_artifacts"])
  end
end
