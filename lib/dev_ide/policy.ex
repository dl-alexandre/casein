defmodule DevIDE.Policy do
  @moduledoc """
  Single decision point for sensitive actions in dev_ide.

  Pure functions — every check returns `%DevIDE.Policy.Decision{}`. Callers
  must funnel here **before** doing the work and **before** mutating any
  state. Audit logging is the caller's responsibility (`DevIDE.Audit`), but
  every blocked decision is expected to be audited as `policy.blocked`.

  M10 contract:
    * `apply_proposal?` is always denied (`:not_implemented`).
    * `enable_agent_write?` is always denied (`:agent_write_locked` or
      `:shared_stage_guarded` if the mode is set to that).
    * Other actions delegate to the existing allowlists they already used.
  """

  alias DevIDE.Policy.{Decision, WorkspaceMode}

  @type ctx :: %{
          optional(:workspace_id) => String.t(),
          optional(:caps) => list(),
          optional(:command_id) => String.t(),
          optional(:agent_run_id) => String.t(),
          optional(:db_isolation) => atom(),
          optional(:actor_type) => atom()
        }

  ## Action helpers — caller-facing

  def can_view_proposal?(ctx), do: allow(:view_proposal, ctx)
  def can_edit_file?(ctx), do: allow(:edit_file, ctx)

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
      not DevIDE.Commands.allowed?(id) ->
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

  ## Mode resolver

  def mode(ctx) when is_map(ctx) do
    WorkspaceMode.resolve(Map.get(ctx, :workspace_id))
  end

  def mode(_), do: WorkspaceMode.resolve(nil)

  ## Internal builders

  defp allow(action, ctx), do: Decision.allow(action, mode(ctx), Map.delete(ctx, :caps))

  defp deny(action, ctx, reason),
    do: Decision.deny(action, mode(ctx), reason, Map.delete(ctx, :caps))

  defp jx_or_agent?(ctx), do: Map.get(ctx, :actor_type) in [:jx, :agent]
end
