defmodule DevIdeWeb.WorkspaceLive.ProposalPanelComponent do
  @moduledoc """
  Proposals tab as a stateful LiveComponent: owns the proposal list,
  selection, analysis, and pending-confirm state; `proposal:*` events land
  here via `phx-target` instead of routing through the Show LiveView.

  Because component events bypass Show's `:handle_event` authz hook, every
  handler funnels through `PanelGate.gate_event/3` — the same audited
  viewer check the hook applies. The actual write still happens in
  `DevIDE.ProposalApply`, never here or in `DevIDE.Proposals` — see
  test/dev_ide/proposals_no_apply_test.exs.

  Outbound effects go to the parent LV as messages: `{:panel_flash, kind,
  msg}` (components cannot write root flash) and `:proposal_workspace_changed`
  (Show refreshes its tree + git-status hub state after an apply).
  """

  use DevIdeWeb, :live_component

  import DevIdeWeb.WorkspaceLive.Show.Context
  import DevIdeWeb.WorkspaceLive.Show.ProposalPanel, only: [proposal_panel: 1]

  alias DevIDE.{ProposalApply, Proposals}
  alias DevIdeWeb.WorkspaceLive.Show.PanelGate

  # Config assigns the parent passes; everything else is component-private
  # UI state. policy_ctx/home_host_path read these from socket.assigns, so
  # the list must cover what Context needs.
  @config_keys ~w(id workspace current_user workspace_mode_source db_isolation host_path)a

  @impl true
  def update(assigns, socket) do
    first_mount? = not Map.has_key?(socket.assigns, :proposals)

    socket = assign(socket, Map.take(assigns, @config_keys))

    socket =
      if first_mount? do
        socket
        |> assign(:proposal_selected, nil)
        |> assign(:proposal_analysis, nil)
        |> assign(:proposal_pending_confirm, nil)
        |> assign(:proposal_error, nil)
        |> assign(:proposals, [])
        |> load_proposals()
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full min-h-0">
      <.proposal_panel
        proposals={@proposals}
        proposal_selected={@proposal_selected}
        proposal_analysis={@proposal_analysis}
        proposal_pending_confirm={@proposal_pending_confirm}
        proposal_error={@proposal_error}
        target={@myself}
      />
    </div>
    """
  end

  @impl true
  def handle_event("proposal:refresh" = event, _params, socket) do
    PanelGate.gate_event(socket, event, fn ->
      {:noreply, load_proposals(socket)}
    end)
  end

  def handle_event("proposal:select" = event, %{"path" => path}, socket) do
    PanelGate.gate_event(socket, event, fn ->
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
    end)
  end

  def handle_event("proposal:apply" = event, %{"path" => path}, socket) do
    PanelGate.gate_event(socket, event, fn -> do_apply(socket, path, []) end)
  end

  def handle_event("proposal:apply_confirm" = event, %{"path" => path}, socket) do
    PanelGate.gate_event(socket, event, fn -> do_apply(socket, path, confirm_overlap: true) end)
  end

  def handle_event("proposal:apply_cancel" = event, _params, socket) do
    PanelGate.gate_event(socket, event, fn ->
      {:noreply, assign(socket, :proposal_pending_confirm, nil)}
    end)
  end

  def load_proposals(socket) do
    case home_host_path(socket) do
      {:ok, root} -> assign(socket, :proposals, Proposals.discover(root))
      :error -> socket
    end
  end

  defp do_apply(socket, path, opts) do
    ctx = policy_ctx(socket, %{target_ref: path})

    case home_host_path(socket) do
      {:ok, root} ->
        case ProposalApply.apply(root, path, ctx, opts) do
          {:ok, result} ->
            send(
              self(),
              {:panel_flash, :info, "Applied #{path} (#{length(result.applied_files)} file(s))"}
            )

            send(self(), :proposal_workspace_changed)

            {:noreply,
             socket
             |> assign(
               proposal_pending_confirm: nil,
               proposal_selected: nil,
               proposal_analysis: nil
             )
             |> load_proposals()}

          {:error, {:policy, decision}} ->
            send(self(), {:panel_flash, :error, "Not allowed: #{decision.reason}"})
            {:noreply, assign(socket, :last_decision, decision)}

          {:error, {:conflict, _analysis}} ->
            send(
              self(),
              {:panel_flash, :error, "Blocked: proposal conflicts with workspace changes"}
            )

            {:noreply, socket}

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
