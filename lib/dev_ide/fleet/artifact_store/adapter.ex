defmodule DevIDE.Fleet.ArtifactStore.Adapter do
  @moduledoc "Behaviour for durable execution artifact chunk storage."

  @type chunk :: %{
          stream: String.t(),
          data: binary(),
          timestamp: DateTime.t(),
          byte_size: non_neg_integer()
        }

  @callback append_chunk(String.t(), String.t(), binary(), DateTime.t()) :: :ok | {:error, term()}
  @callback chunks(String.t()) :: [chunk()]
  @callback chunks_since(String.t(), DateTime.t()) :: [chunk()]
  @callback clear() :: :ok
end
