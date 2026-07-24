defmodule Casein.Logs.Adapter do
  @moduledoc """
  Behaviour for workspace log streaming backends.

  LiveViews depend on this module, not on a specific transport. The default
  adapter is `Casein.Logs.SSE`, which streams from the manager API. A
  `Casein.Logs.DockerCompose` fallback can be wired in later without changing
  callers.
  """

  @type ref :: reference()

  @callback start_stream(workspace_id :: String.t(), service :: String.t(), pid()) ::
              {:ok, ref()} | {:error, term()}

  @callback stop_stream(ref()) :: :ok

  @default_adapter :"Elixir.Casein.Logs.SSE"

  def start_stream(workspace_id, service, pid \\ self()),
    do: impl().start_stream(workspace_id, service, pid)

  def stop_stream(ref), do: impl().stop_stream(ref)

  defp impl, do: Application.get_env(:casein, :logs_adapter, @default_adapter)
end
