defmodule DevIdeWeb.WorkspaceLive.Show.RunEvents do
  # Run / workflow / run-ledger handle_event clauses extracted verbatim from
  # DevIdeWeb.WorkspaceLive.Show (pure code motion — no behavior change). Show
  # delegates "run:*", "run_ledger:*" and "workflow:*" events here. The run
  # execution helpers stay in Show (they are entangled with the pane/ghostty/raw
  # session subsystem and Show's handle_async callbacks) and are called via
  # Show.* — interactive_agent?, launch_interactive_agent, start_batch_run,
  # refresh_run_ledger, attach_existing_run.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView
  import DevIdeWeb.WorkspaceLive.Show.Context

  alias DevIDE.Commands
  alias DevIDE.Runners
  alias DevIDE.Runs.Ledger
  alias DevIdeWeb.WorkspaceLive.Show

  def handle_event("run:start", %{"id" => id}, socket) do
    if Show.interactive_agent?(id) do
      Show.launch_interactive_agent(socket, id)
    else
      Show.start_batch_run(socket, id)
    end
  end

  def handle_event("workflow:hint", _, socket) do
    {:noreply,
     socket
     |> assign(:palette_open, false)
     |> put_flash(
       :info,
       "This workflow needs a bit more detail — type the full command in the safe command line below."
     )}
  end

  def handle_event("workflow:run", %{"command-id" => command_id}, socket) do
    workspace_id = socket.assigns.workspace.id
    run_id = Ledger.new_run_id()

    case Runners.enqueue_command(workspace_id, command_id,
           requested_by: current_actor_id(socket),
           metadata: %{
             source: "ui",
             trigger: "palette_workflow",
             run_id: run_id,
             protocol: Runners.protocol()
           }
         ) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> assign(:palette_open, false)
         |> put_flash(
           :info,
           "Got it — your workflow is queued. Check the Run tab to follow along."
         )
         |> Show.refresh_run_ledger(run_id)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:palette_open, false)
         |> put_flash(:error, "Sorry, that workflow can't run right now (#{inspect(reason)}).")}
    end
  end

  def handle_event("run_ledger:select", %{"id" => id}, socket) do
    {:noreply, Show.refresh_run_ledger(socket, id)}
  end

  def handle_event("run_ledger:open", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:tab, "run")
     |> assign(:audit_drawer_open, false)
     |> Show.attach_existing_run()
     |> Show.refresh_run_ledger(id)}
  end

  def handle_event("run:cancel", _, socket) do
    case Commands.Run.whereis(socket.assigns.workspace.id) do
      {:ok, pid} -> Commands.Run.cancel(pid)
      _ -> :ok
    end

    {:noreply, socket}
  end
end
