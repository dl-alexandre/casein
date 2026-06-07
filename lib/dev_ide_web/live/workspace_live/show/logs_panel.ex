defmodule DevIdeWeb.WorkspaceLive.Show.LogsPanel do
  @moduledoc false

  use DevIdeWeb, :html

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
        <p class="text-xs text-amber-700">
          <%= if DevIDE.WorkspaceSource.impl() == DevIDE.WorkspaceSource.Local do %>
            Log streaming is not available for local filesystem workspaces.
          <% else %>
            Log stream unavailable (source unreachable or service not started).
          <% end %>
        </p>
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
