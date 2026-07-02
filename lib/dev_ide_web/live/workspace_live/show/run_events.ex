defmodule DevIdeWeb.WorkspaceLive.Show.RunEvents do
  # Run / workflow / run-ledger handle_event clauses extracted from
  # DevIdeWeb.WorkspaceLive.Show. Show delegates "run:*", "run_ledger:*",
  # "workflow:*" and "agent:*" events here. Interactive coding-agent launches
  # bridge to the raw terminal via Show.* — interactive_agent?,
  # launch_interactive_agent, refresh_run_ledger. "agent:start_review_run" is
  # the first real caller of the server-spawned review-agent run lifecycle
  # (DevIDE.Agents.Run, DevIDE.Policy.can_start_review_agent?/1) — both were
  # already-built scaffolding with zero production callers until now.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView
  import DevIdeWeb.WorkspaceLive.Show.Context

  alias DevIDE.{Agents, Policy}
  alias DevIDE.Agents.ReviewCommand
  alias DevIDE.Policy.Decision
  alias DevIDE.Proposals.AutoApply
  alias DevIDE.Runs.Ledger
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

  @doc """
  Starts a review-mode agent run (`DevIDE.Agents.Run`, fixed allowlisted argv
  from `DevIDE.Agents.ReviewCommand` — no arbitrary command, no prompt, no
  patch apply). Gated by `Policy.can_start_review_agent?/1`; the ledger entry
  makes the run visible in the Run tab exactly like any other run event.
  """
  def handle_event("agent:start_review_run", %{"id" => id}, socket) do
    case context_host_path(socket) do
      {:ok, root} ->
        ws = socket.assigns.workspace
        caps = Agents.detect(root, ws)

        {decision, socket} =
          gate(
            socket,
            fn ->
              Policy.can_start_review_agent?(policy_ctx(socket, %{agent_run_id: id, caps: caps}))
            end,
            %{action: "agent.start_review_run", target_type: "review_run", target_ref: id}
          )

        if Decision.allow?(decision) do
          start_review_run(socket, ws, root, id, caps)
        else
          {:noreply, put_flash(socket, :error, "Not allowed: #{decision.reason}")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @doc """
  Loads the review-agent command list with per-command capability
  availability. Called from switch_tab (tab == "run") so DevIDE.Agents.detect
  runs once per tab switch, not once per render.
  """
  def load_review_commands(socket) do
    case context_host_path(socket) do
      {:ok, root} ->
        caps = Agents.detect(root, socket.assigns.workspace)
        commands = Enum.map(ReviewCommand.all(), &{&1, ReviewCommand.available?(&1, caps)})
        assign(socket, :review_commands, commands)

      :error ->
        socket
    end
  end

  defp start_review_run(socket, ws, root, id, caps) do
    case Agents.Run.start(ws.id, root, id, caps) do
      {:ok, pid} ->
        run_id = Ledger.new_run_id()

        case ReviewCommand.fetch(id) do
          {:ok, cmd} ->
            Ledger.run_started(%{
              workspace_id: ws.id,
              actor_id: current_actor_id(socket),
              command_id: id,
              run_id: run_id,
              metadata: %{argv: cmd.argv}
            })

            # No-op today for output_kind: :diagnostic (the only allowlisted
            # command) — AutoApply.maybe_auto_apply/3 only fires for
            # output_kind: :proposal. Wired here so it activates the moment a
            # real proposal-producing ReviewCommand exists, with no further
            # LiveView changes needed.
            _ =
              AutoApply.watch(ws.id, root, pid, %{run_id: run_id, command_id: id})

          :error ->
            :ok
        end

        {:noreply,
         socket
         |> put_flash(:info, "Started review run: #{id}")
         |> assign(:tab, "run")
         |> Show.refresh_run_ledger(run_id)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not start review run: #{inspect(reason)}")}
    end
  end
end
