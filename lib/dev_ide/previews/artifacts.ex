defmodule DevIDE.Previews.Artifacts do
  @moduledoc """
  Facade for persisting and resolving preview screenshot artifacts.

  Writes route through the pluggable `DevIDE.Previews.Storage` behaviour
  (`LocalDisk` by default), so screenshots and recordings share one storage path
  and a future object-store adapter drops in without touching callers.
  """

  alias DevIDE.Previews.Storage
  alias DevIDE.Previews.Storage.LocalDisk

  @doc "Store PNG bytes and return a browser-servable path."
  @spec store_png!(String.t(), integer(), binary()) :: String.t()
  def store_png!(workspace_id, observation_id, png_bytes)
      when is_binary(workspace_id) and is_integer(observation_id) and is_binary(png_bytes) do
    {:ok, ref} =
      Storage.put(workspace_id, Integer.to_string(observation_id), "png", {:bytes, png_bytes})

    ref
  end

  @doc "Resolve an artifact path under the artifacts root, rejecting traversal."
  @spec safe_path!(String.t(), String.t()) :: Path.t()
  defdelegate safe_path!(workspace_id, filename), to: LocalDisk
end
