defmodule DevIDE.Policy do
  @moduledoc """
  Single decision point for sensitive actions in dev_ide.

  Pure functions — every check returns `%DevIDE.Policy.Decision{}`. Callers
  must funnel here **before** doing the work and **before** mutating any
  state. Audit logging is the caller's responsibility. Generic blocked
  decisions use `policy.blocked`; command-plane denials use
  `DevIDE.Runs.Ledger` events such as `run.command_denied`.

  M10 contract:
    * `apply_proposal?` is real logic as of the `ProposalApply` write path —
      operator + `:manual` mode + not isolation-blocked (see below).
    * `enable_agent_write?` is real logic as of the reviewed unlock flow —
      `:manual` mode + an active, explicit, time-boxed, human-granted unlock
      (`Workspaces.grant_agent_write_unlock/3`) + not isolation-blocked.
      `:shared_stage_guarded`/`:unsafe_db` are checked first and
      unconditionally — no unlock state can override them.
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

  def can_edit_file?(ctx) do
    if workspace_operator?(ctx),
      do: allow(:edit_file, ctx),
      else: deny(:edit_file, ctx, :forbidden)
  end

  # Raw shell is fail-safe by default: local host + manual workspace mode only.
  # Set `:raw_terminal_everywhere` to true for deliberately permissive
  # single-user/dev deployments.
  def can_use_raw_terminal?(ctx) do
    cond do
      raw_terminal_everywhere?() ->
        allow(:raw_terminal, ctx)

      not local_host?(Map.get(ctx, :host_id)) ->
        deny(:raw_terminal, ctx, :requires_local_host)

      mode(ctx) != :manual ->
        deny(:raw_terminal, ctx, :requires_manual_mode)

      true ->
        allow(:raw_terminal, ctx)
    end
  end

  @doc """
  Applying a discovered proposal (writing its diff to the working tree).

  Fail-safe by the same precedent as `can_use_raw_terminal?/1`: only a
  workspace operator/owner, only in `:manual` mode, never on a
  shared-stage-guarded or unsafe-DB workspace. This decides *who/when* only —
  conflict-risk gating (clean/overlap/conflict) against the current working
  tree is proposal-specific IO decided by `DevIDE.ProposalApply.apply/4`
  after this check passes, keeping this module's contract pure.
  """
  def can_apply_proposal?(ctx) do
    cond do
      not workspace_operator?(ctx) ->
        deny(:apply_proposal, ctx, :forbidden)

      mode(ctx) != :manual ->
        deny(:apply_proposal, ctx, :requires_manual_mode)

      detect_block(ctx) == :shared_stage_guarded ->
        deny(:apply_proposal, ctx, :shared_stage_guarded)

      detect_block(ctx) == :unsafe_db ->
        deny(:apply_proposal, ctx, :unsafe_db)

      true ->
        allow(:apply_proposal, ctx)
    end
  end

  @doc """
  Whether a server-spawned review-agent run may self-apply its own proposal
  with no per-change human click (`DevIDE.Proposals.AutoApply`).

  `:shared_stage_guarded`/`:unsafe_db` are absolute — checked before mode or
  unlock state, and never overridable by an active unlock. Otherwise requires
  `:manual` mode (same fail-safe precedent as raw terminal and proposal
  apply) plus a currently-active, explicit, human-granted unlock.
  """
  def can_enable_agent_write?(ctx) do
    case detect_block(ctx) do
      :shared_stage_guarded -> deny(:enable_agent_write, ctx, :shared_stage_guarded)
      :unsafe_db -> deny(:enable_agent_write, ctx, :unsafe_db)
      nil -> can_enable_agent_write_when_unblocked?(ctx)
    end
  end

  defp can_enable_agent_write_when_unblocked?(ctx) do
    cond do
      mode(ctx) != :manual ->
        deny(:enable_agent_write, ctx, :requires_manual_mode)

      true ->
        case State.agent_write_unlock_for(Map.get(ctx, :workspace_id)) do
          {:active, _until, _by} -> allow(:enable_agent_write, ctx)
          :expired -> deny(:enable_agent_write, ctx, :agent_write_unlock_expired)
          :inactive -> deny(:enable_agent_write, ctx, :agent_write_locked)
        end
    end
  end

  @doc """
  Human-in-the-loop grant of a workspace-scoped, time-boxed agent-write
  unlock. Same operator/mode/isolation gate as `can_apply_proposal?/1` —
  granting the unlock is itself as sensitive as applying a proposal.
  """
  def can_grant_agent_write_unlock?(ctx) do
    cond do
      Map.get(ctx, :workspace_mode_source) == :config ->
        deny(:grant_agent_write_unlock, ctx, :config_override)

      not workspace_operator?(ctx) ->
        deny(:grant_agent_write_unlock, ctx, :forbidden)

      mode(ctx) != :manual ->
        deny(:grant_agent_write_unlock, ctx, :requires_manual_mode)

      detect_block(ctx) == :shared_stage_guarded ->
        deny(:grant_agent_write_unlock, ctx, :shared_stage_guarded)

      detect_block(ctx) == :unsafe_db ->
        deny(:grant_agent_write_unlock, ctx, :unsafe_db)

      true ->
        allow(:grant_agent_write_unlock, ctx)
    end
  end

  @doc """
  The kill switch. Deliberately has no mode/isolation gate — an operator must
  always be able to revoke, regardless of what state made the unlock active
  in the first place.
  """
  def can_revoke_agent_write_unlock?(ctx) do
    if workspace_operator?(ctx),
      do: allow(:revoke_agent_write_unlock, ctx),
      else: deny(:revoke_agent_write_unlock, ctx, :forbidden)
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
      not workspace_operator?(ctx) ->
        deny(:run_command, ctx, :forbidden)

      not command_allowed?(id) ->
        deny(:run_command, ctx, :not_allowed)

      agent_triggered?(ctx) and detect_block(ctx) == :shared_stage_guarded ->
        deny(:run_command, ctx, :shared_stage_guarded)

      agent_triggered?(ctx) and detect_block(ctx) == :unsafe_db ->
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

  defp agent_triggered?(ctx), do: Map.get(ctx, :actor_type) == :agent

  defp raw_terminal_everywhere?,
    do: Application.get_env(:dev_ide, :raw_terminal_everywhere, false) == true

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
