defmodule DevIDE.Logs.Adapter do
  @moduledoc """
  Behaviour for workspace log streaming backends.

  LiveViews depend on this module, not on a specific transport. The default
  adapter is `DevIDE.Logs.SSE`, which streams from the manager API. A
  `DevIDE.Logs.DockerCompose` fallback can be wired in later without changing
  callers.
  """

  @type ref :: reference()

  @callback start_stream(workspace_id :: String.t(), service :: String.t(), pid()) ::
              {:ok, ref()} | {:error, term()}

  @callback stop_stream(ref()) :: :ok

  def start_stream(workspace_id, service, pid \\ self()),
    do: impl().start_stream(workspace_id, service, pid)

  def stop_stream(ref), do: impl().stop_stream(ref)

  defp impl, do: Application.get_env(:dev_ide, :logs_adapter, DevIDE.Logs.SSE)
end
