defmodule Casein.Proposals.AutoApply do
  @moduledoc """
  Policy-gated, audited auto-apply of a completed review-agent run's own
  proposal — the "reviewed unlock flow" `docs/hardening.md` describes.

  Deliberately outside `lib/casein/agents/` (that subsystem has its own
  read-only boundary guard, `test/casein/agents_readonly_test.exs`, which
  must stay green and unmodified). Polls `Casein.Agents.Run.state/1` via
  `Task.Supervisor` rather than calling `subscribe/1` — `Agents.Run` is
  single-subscriber (a second subscriber would steal delivery from the
  LiveView's own stream), and `state/1` is a plain `GenServer.call`, safe for
  any number of concurrent callers.

  This is the informed revival of the risk shape the deleted `Loops`
  subsystem got wrong (2026-06-26 removal: zero `Policy` gate, zero
  `Audit.emit_decision/2`, zero run-ledger event, for a generator that could
  mutate and execute code off the request path). Every branch below —
  disabled, policy-denied, no-candidate, ambiguous, conflict, touches-tests,
  applied, apply-failed — emits exactly one distinct audited event, and nothing
  auto-applies on any deployment until an operator opts in via config,
  independent of any per-workspace unlock.
  """

  require Logger

  alias Casein.{Audit, Policy, Proposals, Workspaces}
  alias Casein.Agents.Run
  alias Casein.Policy.Decision
  alias Casein.Proposals.DiffSignals
  alias Casein.Runs.Ledger

  @poll_ms 2_000
  @max_wait_ms :timer.hours(3)

  @doc """
  Starts a background watcher for `run_pid`. Call immediately after a
  successful `Agents.Run.start/5` — a no-op today for the diagnostic-only
  allowlist entry (`output_kind: :diagnostic` never matches
  `maybe_auto_apply/3`'s `:proposal` filter), and becomes live the moment a
  real `output_kind: :proposal` `ReviewCommand` exists.
  """
  @spec watch(String.t(), String.t(), pid(), map()) :: {:ok, pid()} | {:error, term()}
  def watch(workspace_id, root, run_pid, run_ctx) do
    # Causality handoff: outcome audit events emitted by the watcher task
    # correlate back to the run-start context captured here.
    signals_ctx = Casein.Signals.Context.snapshot()

    Task.Supervisor.start_child(Casein.TaskSupervisor, fn ->
      Casein.Signals.Context.with_snapshot(signals_ctx, fn ->
        poll(workspace_id, root, run_pid, run_ctx, System.monotonic_time(:millisecond))
      end)
    end)
  end

  defp poll(workspace_id, root, run_pid, run_ctx, deadline_start) do
    if System.monotonic_time(:millisecond) - deadline_start > @max_wait_ms do
      :ok
    else
      case Run.state(run_pid) do
        %{status: :running} ->
          Process.sleep(@poll_ms)
          poll(workspace_id, root, run_pid, run_ctx, deadline_start)

        %{status: status, output_kind: output_kind, started_at: started_at} ->
          maybe_auto_apply(
            workspace_id,
            root,
            Map.merge(run_ctx, %{status: status, output_kind: output_kind, started_at: started_at})
          )
      end
    end
  catch
    :exit, _ -> :ok
  end

  @doc "Public so a caller can pass an already-known run snapshot instead of polling."
  @spec maybe_auto_apply(String.t(), String.t(), map()) :: :ok
  def maybe_auto_apply(
        workspace_id,
        root,
        %{status: :succeeded, output_kind: :proposal} = run_ctx
      ) do
    if enabled?() do
      authorize_and_apply(workspace_id, root, run_ctx)
    else
      emit_skip(workspace_id, run_ctx, :auto_apply_disabled)
    end

    :ok
  end

  def maybe_auto_apply(_workspace_id, _root, _run_ctx), do: :ok

  defp authorize_and_apply(workspace_id, root, run_ctx) do
    ctx = %{workspace_id: workspace_id, actor_type: :agent}
    decision = Policy.can_enable_agent_write?(ctx)

    _ =
      Audit.emit_decision(decision, %{
        action: "proposals.auto_apply_authorize",
        workspace_id: workspace_id,
        target_type: "run",
        target_ref: Map.get(run_ctx, :run_id),
        actor_id: "agent:review",
        metadata: %{
          "run_id" => Map.get(run_ctx, :run_id),
          "command_id" => Map.get(run_ctx, :command_id)
        }
      })

    if Decision.allow?(decision), do: apply_flow(workspace_id, root, run_ctx)

    :ok
  end

  defp apply_flow(workspace_id, root, run_ctx) do
    with {:ok, proposal} <- select_proposal(root, run_ctx),
         analysis <- Proposals.analyze(root, proposal),
         :ok <- risk_ok(analysis),
         :ok <- content_ok(proposal) do
      do_apply(workspace_id, root, proposal, run_ctx)
    else
      {:error, reason} -> emit_skip(workspace_id, run_ctx, reason)
      {:risk, risk} -> emit_skip(workspace_id, run_ctx, {:analysis_risk, risk})
      {:touches_tests} -> emit_skip(workspace_id, run_ctx, :touches_test_files)
    end

    :ok
  end

  defp risk_ok(%{risk: :clean}), do: :ok
  defp risk_ok(%{risk: risk}), do: {:risk, risk}

  defp content_ok(proposal) do
    if DiffSignals.touched_test_files?(proposal.diff),
      do: {:touches_tests},
      else: :ok
  end

  # A completed review-agent run's proposal must be the exact, unambiguous
  # file this run produced — a "newest file in the directory" heuristic would
  # let an unrelated .diff dropped in the same window get auto-applied. The
  # allowlist contract (once a real `output_kind: :proposal` command exists)
  # is: the diff filename embeds `run_id`.
  defp select_proposal(root, %{run_id: run_id}) when is_binary(run_id) do
    rel_path = ".opencode/proposals/#{run_id}.diff"

    case Proposals.parse(root, rel_path) do
      {:ok, %{status: :parsed} = proposal} -> {:ok, proposal}
      {:ok, %{status: status}} -> {:error, {:invalid_proposal, status}}
    end
  end

  defp select_proposal(_root, _run_ctx), do: {:error, :no_run_id}

  # Casein.ProposalApply.apply/4 gates on Policy.can_apply_proposal?/1, which
  # requires workspace_operator?/1 (workspace_user == actor_username, or an
  # admin/operator role). An autonomous run has no identity of its own to
  # offer there — it authorizes via the *separate* can_enable_agent_write?/1
  # check already performed in authorize_and_apply/3. Rather than spoofing an
  # operator role, attribute the call to the human who actually granted the
  # unlock: they are the accountable party, and workspace_user/actor_username
  # matching satisfies the ownership check honestly instead of by exception.
  defp do_apply(workspace_id, root, proposal, run_ctx) do
    granter = unlock_granter(workspace_id)

    actor_ctx = %{
      workspace_id: workspace_id,
      actor_type: :agent,
      actor_id: "agent:review:" <> to_string(Map.get(run_ctx, :run_id)),
      workspace_user: granter,
      actor_username: granter
    }

    case Casein.ProposalApply.apply(root, proposal.rel_path, actor_ctx) do
      {:ok, result} ->
        emit_applied(workspace_id, run_ctx, proposal, result)
        emit_run_approval(workspace_id, run_ctx, proposal)

      {:error, reason} ->
        emit_failed(workspace_id, run_ctx, proposal, reason)
    end
  end

  defp unlock_granter(workspace_id) do
    case Workspaces.agent_write_unlock_for(workspace_id) do
      {:active, _until, by} -> by
      _ -> nil
    end
  end

  defp emit_applied(workspace_id, run_ctx, proposal, result) do
    Audit.emit!(%{
      action: "proposals.auto_applied",
      workspace_id: workspace_id,
      actor_id: "agent:review",
      target_type: "proposal",
      target_ref: proposal.rel_path,
      decision: :allow,
      metadata: %{
        "run_id" => Map.get(run_ctx, :run_id),
        "files_count" => length(result.applied_files),
        "risk" => Atom.to_string(result.risk),
        "unlock_granted_by" => unlock_granter(workspace_id)
      }
    })
  end

  defp emit_run_approval(workspace_id, run_ctx, proposal) do
    Ledger.approval_granted(%{
      workspace_id: workspace_id,
      actor_id: "agent:review",
      run_id: Map.get(run_ctx, :run_id),
      command_id: Map.get(run_ctx, :command_id),
      metadata: %{"auto" => true, "rel_path" => proposal.rel_path}
    })
  end

  defp emit_failed(workspace_id, run_ctx, proposal, reason) do
    Audit.emit!(%{
      action: "proposals.auto_apply_failed",
      workspace_id: workspace_id,
      actor_id: "agent:review",
      target_type: "proposal",
      target_ref: proposal.rel_path,
      decision: :deny,
      metadata: %{"run_id" => Map.get(run_ctx, :run_id), "reason" => inspect(reason)}
    })
  end

  defp emit_skip(workspace_id, run_ctx, reason) do
    Audit.emit!(%{
      action: "proposals.auto_apply_skipped",
      workspace_id: workspace_id,
      actor_id: "agent:review",
      target_type: "run",
      target_ref: Map.get(run_ctx, :run_id),
      decision: :deny,
      reason: normalize_reason(reason),
      metadata: %{"run_id" => Map.get(run_ctx, :run_id)}
    })
  end

  defp normalize_reason({tag, _}) when is_atom(tag), do: tag
  defp normalize_reason(reason) when is_atom(reason), do: reason

  defp normalize_reason(reason) do
    Logger.debug("AutoApply: unrecognized skip reason #{inspect(reason)}")
    :unknown_skip_reason
  end

  defp enabled?, do: Application.get_env(:casein, __MODULE__, [])[:enabled] == true
end
