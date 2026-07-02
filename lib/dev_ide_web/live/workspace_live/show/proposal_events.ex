defmodule DevIdeWeb.WorkspaceLive.Show.ProposalEvents do
  # Proposals-tab handle_event clauses for DevIdeWeb.WorkspaceLive.Show. Show
  # delegates "proposal:*" events here. Cross-cutting helpers come from
  # Show.Context (gate/policy_ctx/home_host_path). The actual write happens in
  # DevIDE.ProposalApply, never in this module or in DevIDE.Proposals —
  # see test/dev_ide/proposals_no_apply_test.exs.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView
  import DevIdeWeb.WorkspaceLive.Show.Context

  alias DevIDE.{ProposalApply, Proposals}
  alias DevIdeWeb.WorkspaceLive.Show

  @doc "Loads the proposal list for the workspace home root. Called from switch_tab too."
  def load_proposals(socket) do
    case home_host_path(socket) do
      {:ok, root} -> assign(socket, :proposals, Proposals.discover(root))
      :error -> socket
    end
  end

  def handle_event("proposal:refresh", _params, socket) do
    {:noreply, load_proposals(socket)}
  end

  def handle_event("proposal:select", %{"path" => path}, socket) do
    with {:ok, root} <- home_host_path(socket),
         {:ok, proposal} <- Proposals.parse(root, path) do
      {:noreply,
       socket
       |> assign(:proposal_selected, proposal)
       |> assign(:proposal_analysis, Proposals.analyze(root, proposal))
       |> assign(:proposal_pending_confirm, nil)
       |> assign(:proposal_error, nil)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("proposal:apply", %{"path" => path}, socket),
    do: do_apply(socket, path, [])

  def handle_event("proposal:apply_confirm", %{"path" => path}, socket),
    do: do_apply(socket, path, confirm_overlap: true)

  def handle_event("proposal:apply_cancel", _params, socket) do
    {:noreply, assign(socket, :proposal_pending_confirm, nil)}
  end

  defp do_apply(socket, path, opts) do
    ctx = policy_ctx(socket, %{target_ref: path})

    case home_host_path(socket) do
      {:ok, root} ->
        case ProposalApply.apply(root, path, ctx, opts) do
          {:ok, result} ->
            {:noreply,
             socket
             |> put_flash(:info, "Applied #{path} (#{length(result.applied_files)} file(s))")
             |> assign(
               proposal_pending_confirm: nil,
               proposal_selected: nil,
               proposal_analysis: nil
             )
             |> load_proposals()
             |> Show.refresh_tree()
             |> Show.refresh_git_status()}

          {:error, {:policy, decision}} ->
            {:noreply,
             socket
             |> assign(:last_decision, decision)
             |> put_flash(:error, "Not allowed: #{decision.reason}")}

          {:error, {:conflict, _analysis}} ->
            {:noreply,
             put_flash(socket, :error, "Blocked: proposal conflicts with workspace changes")}

          {:error, {:confirmation_required, analysis}} ->
            {:noreply,
             socket
             |> assign(:proposal_pending_confirm, path)
             |> assign(:proposal_analysis, analysis)}

          {:error, reason} ->
            {:noreply, assign(socket, :proposal_error, inspect(reason))}
        end

      :error ->
        {:noreply, socket}
    end
  end
end
