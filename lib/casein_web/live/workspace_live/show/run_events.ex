defmodule CaseinWeb.WorkspaceLive.Show.RunEvents do
  # Owner of the run region's socket state: run/workflow/run-ledger
  # handle_event clauses plus the ledger/active-run mutators
  # (refresh_run_ledger, apply_run_data/apply_run_exit). Show delegates
  # "run:*", "run_ledger:*", and "workflow:*" events here.
  #
  # This region deliberately stays on the root LiveView rather than becoming
  # a LiveComponent: the command palette dispatches run:start/workflow:* back
  # through Show.handle_event, the audit drawer fires run_ledger:open, run
  # output arrives as {:run_data, ...} handle_info messages, and the handlers
  # write hub state (tab, palette_open, audit_drawer_open). The run panel
  # itself is a pure attr-contracted function component (RunPanel).
  #
  # Interactive coding-agent launches bridge to the raw terminal via Show.* —
  # interactive_agent?, launch_interactive_agent.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView
  import CaseinWeb.WorkspaceLive.Show.Context

  alias Casein.BoundedBuffer
  alias Casein.Export.WorkspaceStatus
  alias Casein.Policy
  alias Casein.Runs.Ledger
  alias Casein.Runs.Status
  alias CaseinWeb.WorkspaceLive.Show

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
    {:noreply, refresh_run_ledger(socket, id)}
  end

  def handle_event("run_ledger:open", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:tab, "run")
     |> assign(:audit_drawer_open, false)
     |> refresh_run_ledger(id)}
  end

  def handle_event("run:cancel", _, socket) do
    {:noreply, socket}
  end

  def refresh_run_ledger(socket, selected_run_id \\ nil) do
    ws_id = socket.assigns.workspace.id
    summaries = Ledger.recent_runs_for(ws_id, 20)

    selected_run_id =
      selected_run_id || socket.assigns[:selected_run_id] || first_run_id(summaries)

    timeline =
      case selected_run_id do
        id when is_binary(id) -> Ledger.timeline_for(ws_id, id)
        _ -> []
      end

    summary =
      case selected_run_id do
        id when is_binary(id) -> Enum.find(summaries, &(&1.id == id))
        _ -> nil
      end

    failure_reason = Status.failure_reason(summary, timeline)

    socket
    |> assign(:run_ledger, summaries)
    |> assign(:selected_run_id, selected_run_id)
    |> assign(:selected_run_summary, summary)
    |> assign(:selected_run_timeline, timeline)
    |> assign(:selected_run_artifacts, WorkspaceStatus.run_artifacts(summary || %{}))
    |> assign(:selected_run_failure_reason, failure_reason)
    |> assign(
      :selected_run_can_retry,
      Status.retryable?(summary, &decision_for_command(socket, &1))
    )
  end

  # Batch command runs were retired with the delegated-execution stack; there
  # is no longer an in-flight run process to re-attach to.
  def attach_existing_run(socket), do: socket

  @run_buffer_cap 256 * 1024

  @doc "Appends a {:run_data, ...} chunk to the active run's bounded buffer."
  def apply_run_data(socket, bin) do
    run = socket.assigns.active_run

    updated =
      Map.update!(run, :buffer, fn buffer ->
        BoundedBuffer.append(buffer, bin, @run_buffer_cap, truncation_marker: "[…truncated]\n")
      end)

    assign(socket, :active_run, updated)
  end

  @doc "Finalizes the active run on {:run_exit, ...} and refreshes the ledger."
  def apply_run_exit(socket, code, status) do
    run = socket.assigns.active_run
    updated = %{run | exit_code: code, status: status, finished_at: DateTime.utc_now()}

    socket
    |> assign(:active_run, updated)
    |> refresh_run_ledger(run.run_id)
  end

  defp first_run_id([%{id: id} | _]) when is_binary(id), do: id
  defp first_run_id(_), do: nil

  defp decision_for_command(socket, command_id) do
    ctx = policy_ctx(socket, %{command_id: command_id})
    Policy.can_run_command?(ctx)
  end
end
