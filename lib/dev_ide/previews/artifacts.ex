defmodule DevIDE.Previews.Artifacts do
  @moduledoc """
  Persists preview screenshot artifacts to servable static paths.
  """

  @doc "Store PNG bytes and return a browser-servable path."
  @spec store_png!(String.t(), integer(), binary()) :: String.t()
  def store_png!(workspace_id, observation_id, png_bytes)
      when is_binary(workspace_id) and is_integer(observation_id) and is_binary(png_bytes) do
    dir = Path.join([artifacts_root(), workspace_id])
    File.mkdir_p!(dir)

    filename = "#{observation_id}.png"
    path = Path.join(dir, filename)
    File.write!(path, png_bytes)
    "/preview-artifacts/#{workspace_id}/#{filename}"
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
