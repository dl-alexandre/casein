defmodule Casein.Agents.JidoActions.Result do
  @moduledoc """
  Distinct machine-readable results for typed Jido worker actions.

  Kinds: `ok`, `denied`, `blocked_on_human`, `timeout`, `cancelled`,
  `stale_attempt`, `provider_failure`, `not_yet_supported`, `invalid`.
  """

  alias Casein.Agents.{Activity, AgentEvents, JidoLifecycle}
  alias Casein.Audit

  @kinds ~w(ok denied blocked_on_human timeout cancelled stale_attempt provider_failure not_yet_supported invalid)a

  @denied_errors ~w(denied policy_denied not_allowed worktree_not_assigned worktree_not_found worktree_path_required workspace_not_found workspace_not_allowed workspace_scope_mismatch workspace_root_unavailable absolute_path outside_root backslash_in_path nul_in_path path_not_allowed invalid_path invalid_patch patch_does_not_apply too_large unknown_tool legacy_opencode protected_branch branch_mismatch worktree_mismatch worktree_changed push_not_authorized staged_path_not_allowed staged_path_mismatch credential_material git_scope_required paths_required nothing_to_commit invalid_receipt invalid_receipt_fields invalid_artifacts invalid_allowed_paths invalid_release_sha invalid_head_sha invalid_handoff_id invalid_receipt_id invalid_identity invalid_owner_ref commit_sha_not_allowed worker_merge_forbidden merged_sha_not_allowed invalid_git_outcome receipt_id_required handoff_id_required illegal_conditional_id illegal_origin_id invalid_task_id invalid_lease_id invalid_correlation_id correlation_task_mismatch test_name_alias_not_allowed test_command_required unknown_field invalid_source workcell_not_assigned identity_mismatch head_sha_mismatch idempotency_mismatch reused_handoff_new_sha)a

  @mutating ~w(code_apply_patch code_exec request_clarification request_human_input report_result handoff_evidence git_handoff)

  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @spec normalize(String.t(), term(), map()) :: {:ok, map()} | {:error, map()}
  def normalize(name, result, ctx) when is_binary(name) do
    wrapped = wrap(name, result, ctx)
    record(name, wrapped, ctx)
    tagged(wrapped)
  end

  defp wrap(_name, {:ok, payload}, ctx) when is_map(payload) do
    cond do
      payload[:timed_out] == true or payload["timed_out"] == true ->
        error(:timeout, :timeout, payload, ctx)

      human?(payload) ->
        error(:blocked_on_human, :awaiting_human, payload, ctx)

      true ->
        stamp(%{result: :ok}, payload, ctx)
    end
  end

  defp wrap(_name, {:ok, payload}, ctx) do
    stamp(%{result: :ok, value: payload}, %{}, ctx)
  end

  defp wrap(_name, {:error, :awaiting_human}, ctx),
    do: error(:blocked_on_human, :awaiting_human, %{}, ctx)

  defp wrap(_name, {:error, :timeout}, ctx), do: error(:timeout, :timeout, %{}, ctx)

  defp wrap(_name, {:error, :cancelled}, ctx), do: error(:cancelled, :cancelled, %{}, ctx)

  defp wrap(_name, {:error, :stale_attempt}, ctx),
    do: error(:stale_attempt, :stale_attempt, %{}, ctx)

  defp wrap(_name, {:error, :provider_unavailable}, ctx),
    do: error(:provider_failure, :provider_unavailable, %{}, ctx)

  defp wrap(_name, {:error, :code_tools_unavailable}, ctx),
    do: error(:provider_failure, :provider_unavailable, %{}, ctx)

  defp wrap(_name, {:error, :not_yet_supported}, ctx),
    do: error(:not_yet_supported, :not_yet_supported, %{}, ctx)

  defp wrap(_name, {:error, :legacy_opencode}, ctx),
    do: error(:denied, :legacy_opencode, %{}, ctx)

  defp wrap(_name, {:error, %{error: kind} = reason}, ctx) when is_atom(kind) do
    error(kind_for(kind, reason), kind, reason, ctx)
  end

  defp wrap(_name, {:error, reason}, ctx) when is_atom(reason) do
    error(kind_for(reason, %{}), reason, %{}, ctx)
  end

  defp wrap(_name, {:error, reason}, ctx) do
    error(:invalid, :invalid, %{detail: inspect(reason)}, ctx)
  end

  defp wrap(_name, other, ctx) do
    error(:invalid, :invalid, %{detail: inspect(other)}, ctx)
  end

  defp kind_for(:awaiting_human, _reason), do: :blocked_on_human
  defp kind_for(:timeout, _reason), do: :timeout
  defp kind_for(:cancelled, _reason), do: :cancelled
  defp kind_for(:stale_attempt, _reason), do: :stale_attempt
  defp kind_for(:provider_unavailable, _reason), do: :provider_failure
  defp kind_for(:provider_failure, _reason), do: :provider_failure
  defp kind_for(:code_tools_unavailable, _reason), do: :provider_failure
  defp kind_for(:not_yet_supported, _reason), do: :not_yet_supported
  defp kind_for(:invalid, _reason), do: :invalid
  defp kind_for(:invalid_argument, _reason), do: :invalid
  defp kind_for(:missing_argument, _reason), do: :invalid
  defp kind_for(:missing_workspace_id, _reason), do: :invalid
  defp kind_for(:input_too_large, _reason), do: :invalid
  defp kind_for(:verification_failed, _reason), do: :invalid
  defp kind_for(:execution_failed, _reason), do: :invalid
  defp kind_for(error, _reason) when error in @denied_errors, do: :denied
  defp kind_for(_error, %{result: kind}) when kind in @kinds, do: kind
  defp kind_for(_error, _reason), do: :denied

  defp human?(payload) do
    payload[:status] in [:awaiting_human, "awaiting_human"] or
      payload[:awaiting_human] == true or
      payload[:result] == :blocked_on_human
  end

  defp error(result_kind, error, payload, ctx) do
    base = %{
      result: result_kind,
      error: error,
      retryable: result_kind in [:timeout, :provider_failure],
      awaiting_human: result_kind == :blocked_on_human
    }

    base =
      if result_kind == :blocked_on_human,
        do: Map.put(base, :status, :awaiting_human),
        else: base

    stamp(base, payload, ctx)
  end

  defp stamp(base, payload, ctx) do
    identity = %{
      workspace_id: Map.get(ctx, :workspace_id),
      task_id: Map.get(ctx, :task_id),
      attempt_id: Map.get(ctx, :attempt_id),
      session_id: Map.get(ctx, :session_id),
      workcell_id: Map.get(ctx, :workcell_id),
      worker_id: Map.get(ctx, :worker_id),
      lease_id: Map.get(ctx, :lease_id),
      handoff_id: Map.get(ctx, :handoff_id),
      worktree_path: Map.get(ctx, :worktree_path),
      principal: Map.get(ctx, :principal),
      capability: Map.get(ctx, :capability),
      correlation_id: Map.get(ctx, :correlation_id)
    }

    payload =
      if canonical_receipt?(payload),
        do: Map.merge(identity, payload),
        else: Map.merge(identity, Map.drop(payload, Map.keys(identity)))

    payload
    |> Map.merge(base)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp canonical_receipt?(payload) when is_map(payload) do
    Map.has_key?(payload, :schema_version) and Map.has_key?(payload, :receipt_id) and
      Map.has_key?(payload, :idempotency_key)
  end

  defp canonical_receipt?(_payload), do: false

  defp tagged(%{result: :ok} = payload), do: {:ok, payload}
  defp tagged(payload), do: {:error, payload}

  defp record(name, payload, ctx) do
    workspace_id = Map.get(ctx, :workspace_id) || payload[:workspace_id]

    if is_binary(workspace_id) do
      kind = payload[:result]
      status = if kind == :ok, do: :ok, else: :error
      record_activity(name, workspace_id, kind, status, ctx, payload)
      record_event(name, workspace_id, status, ctx)
      record_audit(name, workspace_id, kind, ctx)
      JidoLifecycle.ingest_action(name, payload, ctx)
    end

    :ok
  end

  defp record_activity(name, workspace_id, kind, status, ctx, payload) do
    Activity.record(%{
      workspace_id: workspace_id,
      source: :jido_actions,
      tool: name,
      summary: summary(name, kind),
      metadata: %{
        result: kind,
        task_id: Map.get(ctx, :task_id) || payload[:task_id],
        attempt_id: Map.get(ctx, :attempt_id) || payload[:attempt_id],
        session_id: Map.get(ctx, :session_id) || payload[:session_id],
        workcell_id: Map.get(ctx, :workcell_id) || payload[:workcell_id],
        worker_id: Map.get(ctx, :worker_id) || payload[:worker_id],
        lease_id: Map.get(ctx, :lease_id) || payload[:lease_id],
        handoff_id: Map.get(ctx, :handoff_id) || payload[:handoff_id],
        correlation_id: Map.get(ctx, :correlation_id) || payload[:correlation_id],
        capability: Map.get(ctx, :capability) || payload[:capability]
      },
      status: status
    })
  end

  defp record_event(name, workspace_id, status, ctx) do
    AgentEvents.append_mcp(
      workspace_id,
      "jido_actions",
      %{
        tool: name,
        actor_id: Map.get(ctx, :principal),
        agent_session_id: Map.get(ctx, :session_id) || Map.get(ctx, :attempt_id)
      },
      status
    )
  end

  defp record_audit(name, workspace_id, kind, ctx) when name in @mutating do
    Audit.emit!(%{
      workspace_id: workspace_id,
      actor_id: Map.get(ctx, :principal) || "jido",
      action: "agent.jido_" <> name,
      source: "jido_actions",
      tool: name,
      metadata: %{
        result: kind,
        task_id: Map.get(ctx, :task_id),
        attempt_id: Map.get(ctx, :attempt_id),
        correlation_id: Map.get(ctx, :correlation_id)
      }
    })
  end

  defp record_audit(_name, _workspace_id, _kind, _ctx), do: :ok

  defp summary(name, :ok), do: "jido #{name}"
  defp summary(name, kind), do: "jido #{name} (#{kind})"
end
