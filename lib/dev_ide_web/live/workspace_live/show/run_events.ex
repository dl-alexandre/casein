defmodule DevIdeWeb.WorkspaceLive.Show.RunEvents do
  # Run / workflow / run-ledger handle_event clauses extracted from
  # DevIdeWeb.WorkspaceLive.Show. Show delegates "run:*", "run_ledger:*" and
  # "workflow:*" events here. Interactive coding-agent launches are the only
  # remaining execution path and bridge to the raw terminal via Show.* —
  # interactive_agent?, launch_interactive_agent, refresh_run_ledger.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView

  alias DevIdeWeb.WorkspaceLive.Show

  def handle_event("run:start", %{"id" => id}, socket) do
    if Show.interactive_agent?(id) do
      Show.launch_interactive_agent(socket, id)
    else
      {:noreply,
       socket
       |> assign(:palette_open, false)
       |> put_flash(
         :info,
         "Batch command runs were retired — open a raw terminal to run commands directly."
       )}
    end
  end

  def handle_event("workflow:hint", _, socket) do
    {:noreply,
     socket
     |> assign(:palette_open, false)
     |> put_flash(
       :info,
       "This workflow needs a bit more detail — type the full command in a raw terminal below."
     )}
  end

  def handle_event("workflow:run", _params, socket) do
    {:noreply,
     socket
     |> assign(:palette_open, false)
     |> put_flash(
       :info,
       "Workflow runs were retired — open a raw terminal to run commands directly."
     )}
  end

  def handle_event("run_ledger:select", %{"id" => id}, socket) do
    {:noreply, Show.refresh_run_ledger(socket, id)}
  end

  def handle_event("run_ledger:open", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:tab, "run")
     |> assign(:audit_drawer_open, false)
     |> Show.refresh_run_ledger(id)}
  end

  def handle_event("run:cancel", _, socket) do
    {:noreply, socket}
  end
end
