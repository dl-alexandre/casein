defmodule DevIdeWeb.WorkspaceLive.Show.LogsEvents do
  # Logs-tab mutators for DevIdeWeb.WorkspaceLive.Show. Unlike the proposal
  # panel / audit drawer, logs stay on the root LiveView: log lines arrive as
  # {:source_log, ref, line} handle_info messages, which LiveComponents cannot
  # receive, and forwarding per-line via send_update would churn on busy
  # services. This module just gives the region an owner; the :log_lines
  # stream and :log_service/:log_ref assigns remain root state.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView

  alias DevIDE.Logs

  @max_log_lines 500

  def handle_event("set_log_service", %{"service" => service}, socket) do
    socket =
      socket
      |> assign(:log_service, service)
      |> stream(:log_lines, [], reset: true)

    {:noreply, start_log_stream(socket)}
  end

  def insert_log_line(socket, line) do
    entry = %{id: "log-#{System.unique_integer([:positive])}", text: line}
    stream_insert(socket, :log_lines, entry, at: -1, limit: -@max_log_lines)
  end

  def start_log_stream(socket) do
    case Logs.Adapter.start_stream(
           socket.assigns.workspace.id,
           socket.assigns.log_service,
           self()
         ) do
      {:ok, ref} -> assign(socket, :log_ref, ref)
      {:error, _reason} -> assign(socket, :log_ref, nil)
    end
  end
end
