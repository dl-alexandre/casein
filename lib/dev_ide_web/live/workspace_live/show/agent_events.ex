defmodule DevIdeWeb.WorkspaceLive.Show.AgentEvents do
  # Agent / annotation / audit-drawer handle_event clauses extracted verbatim from
  # DevIdeWeb.WorkspaceLive.Show (pure code motion — no behavior change).
  # Show delegates "agent:*", "annotation:*", and "audit_drawer:*" events here.
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
  alias DevIdeWeb.WorkspaceLive.Show.RunEvents

  def handle_event("audit_drawer:toggle", _params, socket) do
    {:noreply, assign(socket, :audit_drawer_open, not socket.assigns.audit_drawer_open)}
  end

  def handle_event("audit_drawer:close", _params, socket) do
    {:noreply, assign(socket, :audit_drawer_open, false)}
  end

  def handle_event("annotation:open", %{"path" => path} = params, socket) do
    line = parse_line(params["line"])

    case context_host_loc(socket) do
      {:ok, loc} -> {:noreply, Show.open_annotation_file(socket, loc, path, line)}
      _ -> {:noreply, socket}
    end
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
  availability. Called from select_tab (tab == "run") so DevIDE.Agents.detect
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

        # Scoped context (never a bare put): the LiveView process is
        # long-lived, and AutoApply.watch snapshots it before this returns.
        DevIDE.Signals.Context.with_new(fn ->
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
        end)

        {:noreply,
         socket
         |> put_flash(:info, "Started review run: #{id}")
         |> assign(:tab, "run")
         |> RunEvents.refresh_run_ledger(run_id)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not start review run: #{inspect(reason)}")}
    end
  end

  defp parse_line(nil), do: nil
  defp parse_line(""), do: nil

  defp parse_line(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_line(_), do: nil
end
