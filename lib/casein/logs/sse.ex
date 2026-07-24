defmodule Casein.Logs.SSE do
  @moduledoc "SSE log adapter backed by the configured `Casein.WorkspaceSource`."
  @behaviour Casein.Logs.Adapter

  @impl true
  def start_stream(workspace_id, service, pid) do
    case Casein.Workspaces.stream_logs(workspace_id, service, pid) do
      {:ok, ref, _task} -> {:ok, ref}
      other -> other
    end
  end

  @impl true
  def stop_stream(_ref), do: :ok
end
