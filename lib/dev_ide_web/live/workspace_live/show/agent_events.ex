defmodule DevIdeWeb.WorkspaceLive.Show.AgentEvents do
  # Agent / proposal handle_event clauses extracted verbatim from
  # DevIdeWeb.WorkspaceLive.Show (pure code motion — no behavior change). Show
  # delegates "agents:*", "agent_worktree:*", "agent_run:*" and "proposal:*"
  # events here. Helpers entangled with Show's handle_async / mount lifecycle
  # stay in Show and are called via Show.* — load_agents, attach_agent_worktree,
  # attach_existing_agent_run, refresh_audit_stream.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView
  import DevIdeWeb.WorkspaceLive.Show.Context

  alias DevIDE.Annotations
  alias DevIDE.Audit
  alias DevIDE.Policy
  alias DevIDE.Proposals
  alias DevIDE.Proposals.ConflictAnalyzer
  alias DevIdeWeb.WorkspaceLive.Show
  alias DevIdeWeb.WorkspaceLive.Show.TerminalState

  def handle_event("agents:refresh", _, socket), do: {:noreply, Show.load_agents(socket)}

  def handle_event("agent_worktree:attach", %{"runtime-id" => runtime_id}, socket) do
    workspace_id = socket.assigns.workspace.id

    case Enum.find(
           DevIDE.Runtimes.list_agent_worktrees(workspace_id),
           &(&1.runtime_id == runtime_id)
         ) do
      nil ->
        {:noreply, put_flash(socket, :error, "Agent worktree is no longer available.")}

      worktree ->
        {:noreply, Show.attach_agent_worktree(socket, worktree)}
    end
  end

  def handle_event("agent_worktree:compare", %{"runtime-id" => runtime_id}, socket) do
    workspace_id = socket.assigns.workspace.id

    case Enum.find(
           DevIDE.Runtimes.list_agent_worktrees(workspace_id),
           &(&1.runtime_id == runtime_id)
         ) do
      nil ->
        {:noreply, put_flash(socket, :error, "Agent worktree is no longer available.")}

      %{path: path} when is_binary(path) ->
        case DevIDE.Git.diff_all(path) do
          {:ok, ""} ->
            {:noreply, put_flash(socket, :info, "Agent worktree has no local diff.")}

          {:ok, diff} ->
            {:noreply, socket |> assign(:file_diff, diff) |> assign(:tab, "files")}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Could not diff agent worktree: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Agent worktree is missing a path.")}
    end
  end

  def handle_event("proposal:select", %{"path" => path}, socket) do
    {_decision, socket} =
      gate(socket, fn -> Policy.can_view_proposal?(policy_ctx(socket)) end, %{
        action: "proposal.viewed",
        target_type: "proposal",
        target_ref: path
      })

    case host_path(socket) do
      {:ok, root} ->
        case Proposals.parse(root, path) do
          {:ok, p} ->
            analysis = ConflictAnalyzer.analyze(root, p)

            Audit.emit!(%{
              action: "proposal.analyzed",
              workspace_id: socket.assigns.workspace.id,
              actor_id: (socket.assigns[:current_user] || %{}) |> Map.get(:id),
              target_type: "proposal",
              target_ref: path,
              metadata: %{
                "proposal_path" => path,
                "risk" => Atom.to_string(analysis.risk),
                "files_count" => analysis.files_count,
                "overlapping_files_count" => length(analysis.overlapping_files)
              }
            })

            {:noreply,
             socket
             |> assign(:selected_proposal, p)
             |> assign(:proposal_analysis, analysis)
             |> Show.refresh_audit_stream()}

          _ ->
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("proposal:clear", _, socket),
    do: {:noreply, socket |> assign(:selected_proposal, nil) |> assign(:proposal_analysis, nil)}

  def handle_event("agent_run:start", %{"id" => id}, socket) do
    caps = socket.assigns.agent_caps

    {decision, socket} =
      gate(
        socket,
        fn ->
          Policy.can_start_review_agent?(policy_ctx(socket, %{agent_run_id: id, caps: caps}))
        end,
        %{action: "agent.review_started", target_type: "agent_run", target_ref: id}
      )

    with true <- DevIDE.Policy.Decision.allow?(decision),
         {:ok, root} <- host_path(socket),
         {:ok, pid} <-
           DevIDE.Agents.Run.start(socket.assigns.workspace.id, root, id, caps),
         {:ok, snap} <- DevIDE.Agents.Run.subscribe(pid) do
      {:noreply, socket |> assign(:agent_run, snap) |> assign(:agent_run_error, nil)}
    else
      {:error, :already_running} ->
        {:noreply, Show.attach_existing_agent_run(socket)}

      {:error, reason} ->
        {:noreply, assign(socket, :agent_run_error, "Run failed: #{inspect(reason)}")}

      _ ->
        {:noreply, assign(socket, :agent_run_error, "Run not allowed.")}
    end
  end

  def handle_event("agent_run:cancel", _, socket) do
    case DevIDE.Agents.Run.whereis(socket.assigns.workspace.id) do
      {:ok, pid} -> DevIDE.Agents.Run.cancel(pid)
      _ -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("agent_mcp_activity:focus", params, socket) do
    session = activity_value(params, "session")
    pane = activity_value(params, "pane")

    if is_binary(session) or is_binary(pane) do
      {:noreply,
       socket
       |> assign(:agents_panel_open, false)
       |> assign(:tab, "terminal")
       |> TerminalState.focus_activity_target(session, pane)}
    else
      {:noreply, put_flash(socket, :error, "No session or pane to focus.")}
    end
  end

  def handle_event("preview_activity:focus", %{"pane-id" => pane_id}, socket)
      when is_binary(pane_id) and pane_id != "" do
    {:noreply,
     socket
     |> assign(:agents_panel_open, false)
     |> assign(:tab, "terminal")
     |> TerminalState.focus_activity_target(nil, pane_id)}
  end

  def handle_event("preview_activity:focus", _, socket),
    do: {:noreply, put_flash(socket, :error, "No preview pane to focus.")}

  def handle_event("annotation:approve", %{"id" => id}, socket) do
    with {:ok, annotation} <- Annotations.get(id),
         true <- annotation.workspace_id == socket.assigns.workspace.id,
         {:ok, _approved} <-
           Annotations.approve(annotation, %{actor_id: current_actor_id(socket)}) do
      {:noreply,
       socket
       |> Show.refresh_pending_annotations()
       |> put_flash(:info, "Annotation approved.")}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Annotation not found.")}

      false ->
        {:noreply, put_flash(socket, :error, "Annotation belongs to another workspace.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Could not approve annotation.")}
    end
  end

  def handle_event("annotation:reject", %{"id" => id}, socket) do
    with {:ok, annotation} <- Annotations.get(id),
         true <- annotation.workspace_id == socket.assigns.workspace.id,
         {:ok, _rejected} <-
           Annotations.reject(annotation, %{actor_id: current_actor_id(socket)}) do
      {:noreply,
       socket
       |> Show.refresh_pending_annotations()
       |> put_flash(:info, "Annotation rejected.")}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Annotation not found.")}

      false ->
        {:noreply, put_flash(socket, :error, "Annotation belongs to another workspace.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Could not reject annotation.")}
    end
  end

  defp activity_value(params, "session"), do: params["session"] || params[:session]
  defp activity_value(params, "pane"), do: params["pane"] || params[:pane]
end
