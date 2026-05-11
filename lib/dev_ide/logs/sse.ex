defmodule DevIDE.Logs.SSE do
  @moduledoc "SSE log adapter backed by the milc-devbox manager API."
  @behaviour DevIDE.Logs.Adapter

  alias DevIDE.Devbox.ManagerClient

  @impl true
  def start_stream(workspace_id, service, pid) do
    case ManagerClient.stream_logs(workspace_id, service, pid) do
      {:ok, ref, _task} -> {:ok, ref}
      other -> other
    end
  end

  @impl true
  def stop_stream(_ref), do: :ok
end
