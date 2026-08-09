defmodule CaseinWeb.WorkspaceLive.Show.LogsPanel do
  @moduledoc false

  use CaseinWeb, :html

  import CaseinWeb.WorkspaceLive.Show.UI, only: [panel_state: 1]

  attr :log_service, :string, required: true
  attr :log_ref, :any, required: true
  attr :streams, :map, required: true

  def logs_panel(assigns) do
    ~H"""
    <section class="flex h-full min-h-0 flex-col gap-2">
      <.form
        for={%{}}
        phx-change="set_log_service"
        class="flex flex-wrap gap-2 items-center flex-none"
      >
        <label class="text-sm">Service</label>
        <input name="service" value={@log_service} class="border rounded px-2 py-1 text-sm font-mono" />
      </.form>
      <%= if is_nil(@log_ref) do %>
        <%= if Casein.WorkspaceSource.impl() == Casein.WorkspaceSource.Local do %>
          <.panel_state
            id="logs-panel-local-unavailable"
            kind={:degraded}
            title="Logs unavailable"
            message="Log streaming is not available for local filesystem workspaces."
          />
        <% else %>
          <.panel_state
            id="logs-panel-stream-unavailable"
            kind={:error}
            title="Log stream unavailable"
            message="Source unreachable or service not started. Start the service, then re-open Logs."
          />
        <% end %>
      <% end %>
      <pre
        id="log-lines"
        phx-update="stream"
        class="bg-zinc-950 text-zinc-100 text-xs p-3 rounded overflow-auto flex-1 min-h-[12rem] whitespace-pre-wrap font-mono"
      >
        <%= for {dom_id, entry} <- @streams.log_lines do %>
          <span id={dom_id}>{entry.text}</span>
        <% end %>
      </pre>
    </section>
    """
  end
end
