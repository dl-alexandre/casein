defmodule DevIDE.Previews.Artifacts do
  @moduledoc """
  Facade for persisting and resolving preview screenshot artifacts.

  Writes route through the pluggable `DevIDE.Previews.Storage` behaviour
  (`LocalDisk` by default), so screenshots and recordings share one storage path
  and a future object-store adapter drops in without touching callers.
  """

  alias DevIDE.Previews.Storage
  alias DevIDE.Previews.Storage.LocalDisk

  @doc "Store PNG bytes under a named artifact id and return a browser-servable path."
  @spec store_named_png!(String.t(), String.t(), binary()) :: String.t()
  def store_named_png!(workspace_id, artifact_id, png_bytes)
      when is_binary(workspace_id) and is_binary(artifact_id) and is_binary(png_bytes) do
    case Storage.put(workspace_id, artifact_id, "png", {:bytes, png_bytes}) do
      {:ok, ref} ->
        ref

      {:error, reason} ->
        raise ArgumentError,
              "could not store preview PNG for workspace #{inspect(workspace_id)}: #{inspect(reason)}"
    end
  end

  @doc "Store PNG bytes and return a browser-servable path."
  @spec store_png!(String.t(), integer(), binary()) :: String.t()
  def store_png!(workspace_id, observation_id, png_bytes)
      when is_binary(workspace_id) and is_integer(observation_id) and is_binary(png_bytes) do
    store_named_png!(workspace_id, Integer.to_string(observation_id), png_bytes)
  end

  @doc "Resolve an artifact path under the artifacts root, rejecting traversal."
  @spec safe_path!(String.t(), String.t()) :: Path.t()
  defdelegate safe_path!(workspace_id, filename), to: LocalDisk
end
