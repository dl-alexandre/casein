defmodule Casein.Previews.Storage do
  @moduledoc """
  Pluggable persistence for preview artifacts — screenshots and recordings.

  `LocalDisk` (the default) writes servable files under the artifacts root. The
  behaviour is the seam that lets a future `S3`/`GCS` adapter satisfy the same
  contract, so capture and playback are unaffected by where the bytes live.

  A `source` is either in-memory `{:bytes, binary}` (screenshots arrive decoded)
  or a `{:file, path}` already assembled on disk (recordings stream up in chunks
  to a temp file before finalize).
  """

  @type source :: {:bytes, binary()} | {:file, Path.t()}

  @callback put(workspace_id :: String.t(), id :: String.t(), ext :: String.t(), source()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "The configured storage adapter (defaults to local disk)."
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:dev_ide, :preview_storage_adapter, Casein.Previews.Storage.LocalDisk)
  end

  @doc "Persist an artifact and return a browser-servable reference."
  @spec put(String.t(), String.t(), String.t(), source()) :: {:ok, String.t()} | {:error, term()}
  def put(workspace_id, id, ext, source)
      when is_binary(workspace_id) and is_binary(id) and is_binary(ext) do
    adapter().put(workspace_id, id, ext, source)
  end
end
