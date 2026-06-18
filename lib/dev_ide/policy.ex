defmodule DevIDE.Policy do
  @moduledoc """
  Single decision point for sensitive actions in dev_ide.

  Pure functions — every check returns `%DevIDE.Policy.Decision{}`. Callers
  must funnel here **before** doing the work and **before** mutating any
  state. Audit logging is the caller's responsibility. Generic blocked
  decisions use `policy.blocked`; command-plane denials use
  `DevIDE.Runs.Ledger` events such as `run.command_denied`.

  M10 contract:
    * `apply_proposal?` is always denied (`:not_implemented`).
    * `enable_agent_write?` is always denied (`:agent_write_locked` or
      `:shared_stage_guarded` if the mode is set to that).
    * Other actions delegate to the existing allowlists they already used.
  """

  alias DevIDE.Policy.{Decision, WorkspaceMode}
  alias DevIDE.Workspaces.State

  @type ctx :: %{
          optional(:workspace_id) => String.t(),
          optional(:caps) => list(),
          optional(:command_id) => String.t(),
          optional(:agent_run_id) => String.t(),
          optional(:db_isolation) => atom(),
          optional(:actor_type) => atom(),
          optional(:actor_role) => atom() | String.t(),
          optional(:host_id) => String.t()
        }

  ## Action helpers — caller-facing

  def can_view_proposal?(ctx), do: allow(:view_proposal, ctx)
  def can_edit_file?(ctx), do: allow(:edit_file, ctx)

  # Raw shell is universally available — any workspace, any mode, any host —
  # whenever the `:raw_terminal_everywhere` app env is enabled (the default).
  # Set it to `false` to reinstate the old manual-mode-on-local-host gate.
  def can_use_raw_terminal?(ctx) do
    cond do
      Application.get_env(:dev_ide, :raw_terminal_everywhere, true) ->
        allow(:raw_terminal, ctx)

      not local_host?(Map.get(ctx, :host_id)) ->
        deny(:raw_terminal, ctx, :requires_local_host)

      mode(ctx) != :manual ->
        deny(:raw_terminal, ctx, :requires_manual_mode)

      true ->
        allow(:raw_terminal, ctx)
    end
  end

  def can_apply_proposal?(ctx),
    do: deny(:apply_proposal, ctx, :not_implemented)

  def can_enable_agent_write?(ctx) do
    case detect_block(ctx) do
      :shared_stage_guarded -> deny(:enable_agent_write, ctx, :shared_stage_guarded)
      :unsafe_db -> deny(:enable_agent_write, ctx, :unsafe_db)
      _ -> deny(:enable_agent_write, ctx, :agent_write_locked)
    end
  end

  @doc """
  Returns the block reason if the workspace mode or detected DB isolation
  forces a deny, else `nil`. Public so the UI can surface the same wording.
  """
  def block_reason(ctx), do: detect_block(ctx)

  defp detect_block(ctx) do
    cond do
      mode(ctx) == :shared_stage_guarded -> :shared_stage_guarded
      Map.get(ctx, :db_isolation) == :shared_stage -> :shared_stage_guarded
      Map.get(ctx, :db_isolation) == :unsafe -> :unsafe_db
      true -> nil
    end
  end

  def can_run_command?(%{command_id: id} = ctx) do
    cond do
      not command_allowed?(id) ->
        deny(:run_command, ctx, :not_allowed)

      jx_or_agent?(ctx) and detect_block(ctx) == :shared_stage_guarded ->
        deny(:run_command, ctx, :shared_stage_guarded)

      jx_or_agent?(ctx) and detect_block(ctx) == :unsafe_db ->
        deny(:run_command, ctx, :unsafe_db)

      true ->
        allow(:run_command, ctx)
    end
  end

  def can_run_command?(ctx), do: deny(:run_command, ctx, :not_allowed)

  defp command_allowed?(id) do
    DevIDE.Commands.allowed?(id) or match?({:ok, _}, DevIDE.Terminals.Workflows.fetch_command(id))
  end

  def can_start_review_agent?(%{agent_run_id: id, caps: caps} = ctx) do
    case DevIDE.Agents.ReviewCommand.fetch(id) do
      {:ok, cmd} ->
        if DevIDE.Agents.ReviewCommand.available?(cmd, caps),
          do: allow(:start_review_agent, ctx),
          else: deny(:start_review_agent, ctx, :requires_not_met)

      :error ->
        deny(:start_review_agent, ctx, :not_allowed)
    end
  end

  def can_start_review_agent?(ctx), do: deny(:start_review_agent, ctx, :not_allowed)

  @doc """
  Changing workspace mode in the cockpit UI (not config-pinned overrides).
  """
  def can_set_workspace_mode?(ctx) do
    cond do
      Map.get(ctx, :workspace_mode_source) == :config ->
        deny(:set_workspace_mode, ctx, :config_override)

      not workspace_operator?(ctx) ->
        deny(:set_workspace_mode, ctx, :forbidden)

      true ->
        allow(:set_workspace_mode, ctx)
    end
  end

  @doc """
  Resolve the actor's effective role for a workspace.

  Admins/operators can manage shared operational controls. Owners can manage
  their own workspace. Everyone else is a viewer until a narrower collaborator
  role is introduced.
  """
  def workspace_role(ctx) when is_map(ctx) do
    cond do
      admin_or_operator?(ctx) -> :operator
      workspace_owner?(ctx) -> :owner
      true -> :viewer
    end
  end

  def workspace_role(_ctx), do: :viewer

  ## Mode resolver

  def mode(ctx) when is_map(ctx) do
    case Map.get(ctx, :workspace_id) do
      workspace_id when is_binary(workspace_id) ->
        workspace_id
        |> State.mode_for()
        |> elem(0)

      _ ->
        WorkspaceMode.resolve(nil)
    end
  end

  def mode(_), do: WorkspaceMode.resolve(nil)

  ## Internal builders

  defp allow(action, ctx), do: Decision.allow(action, mode(ctx), Map.delete(ctx, :caps))

  defp deny(action, ctx, reason),
    do: Decision.deny(action, mode(ctx), reason, Map.delete(ctx, :caps))

  defp jx_or_agent?(ctx), do: Map.get(ctx, :actor_type) in [:jx, :agent]

  defp local_host?(host_id), do: host_id in ["local", "localhost"]

  defp workspace_owner?(ctx) do
    case {Map.get(ctx, :workspace_user), Map.get(ctx, :actor_username)} do
      {ws_user, actor} when is_binary(ws_user) and is_binary(actor) ->
        String.downcase(ws_user) == String.downcase(actor)

      _ ->
        false
    end
  end

  defp workspace_operator?(ctx), do: workspace_role(ctx) in [:operator, :owner]

  defp admin_or_operator?(ctx) do
    Map.get(ctx, :actor_role)
    |> role()
    |> Kernel.in([:admin, :operator])
  end

  defp role(:admin), do: :admin
  defp role(:operator), do: :operator
  defp role("admin"), do: :admin
  defp role("operator"), do: :operator
  defp role(role) when is_binary(role), do: role |> String.downcase() |> role()
  defp role(_), do: :viewer
end
