defmodule DevIDE.ProposalApply do
  @moduledoc """
  Governed write path for applying a discovered `DevIDE.Proposals.Proposal`
  diff to a workspace's working tree.

  Deliberately lives outside `lib/dev_ide/proposals/` — the read-only
  discovery/parse/analyze subsystem there must never gain a write path (see
  `test/dev_ide/proposals_no_apply_test.exs`). This module is the *only*
  sanctioned write path: it calls `DevIDE.Proposals.parse/2` and
  `DevIDE.Proposals.analyze/2` read-only, then shells out via
  `DevIDE.ProposalApply.GitAdapter`.

  Socket-free by design: runs its own `DevIDE.Policy.can_apply_proposal?/1`
  check and `DevIDE.Audit.emit_decision/2` internally (rather than relying on
  the LiveView-coupled `Show.Context.gate/3`) so both a human's LiveView click
  and a future server-side agent-run hook get identical, un-bypassable
  enforcement.
  """

  alias DevIDE.{Audit, Policy, Proposals}
  alias DevIDE.Policy.Decision
  alias DevIDE.Proposals.{Analysis, Proposal}

  @type apply_error ::
          {:policy, Decision.t()}
          | {:invalid_proposal, atom()}
          | {:too_large_to_apply, non_neg_integer()}
          | {:conflict, Analysis.t()}
          | {:confirmation_required, Analysis.t()}
          | {:git_error, term()}

  @spec apply(String.t(), String.t(), Policy.ctx(), keyword()) ::
          {:ok, %{applied_files: [String.t()], risk: Analysis.risk(), proposal: String.t()}}
          | {:error, apply_error()}
  def apply(root, rel_path, ctx, opts \\ [])
      when is_binary(root) and is_binary(rel_path) and is_map(ctx) do
    decision = Policy.can_apply_proposal?(ctx)

    _ =
      Audit.emit_decision(decision, %{
        workspace_id: Map.get(ctx, :workspace_id),
        actor_id: Map.get(ctx, :actor_id),
        target_type: "proposal",
        target_ref: rel_path
      })

    if Decision.allow?(decision) do
      apply_allowed(root, rel_path, ctx, opts)
    else
      {:error, {:policy, decision}}
    end
  end

  defp apply_allowed(root, rel_path, ctx, opts) do
    with {:ok, %Proposal{status: :parsed, truncated: false} = proposal} <-
           Proposals.parse(root, rel_path),
         analysis <- Proposals.analyze(root, proposal),
         :ok <- risk_gate(analysis, opts) do
      do_apply(root, rel_path, proposal, analysis, ctx, opts)
    else
      {:ok, %Proposal{status: :parsed, truncated: true, size: size}} ->
        audit_blocked(ctx, rel_path, "proposal.apply_blocked", :too_large_to_apply, %{})
        {:error, {:too_large_to_apply, size}}

      {:ok, %Proposal{status: status}} ->
        audit_blocked(ctx, rel_path, "proposal.apply_blocked", :invalid_proposal, %{
          "status" => Atom.to_string(status)
        })

        {:error, {:invalid_proposal, status}}

      {:error, {:conflict, _}} = err ->
        err

      {:error, {:confirmation_required, _}} = err ->
        err
    end
  end

  # `:invalid` covers both an unparseable diff and a path-unsafe header
  # (UnifiedDiff.parse_with_hunks/2 already routed every changed path through
  # PathSafety.resolve/2) — blocked the same as a real conflict, no override.
  defp risk_gate(%Analysis{risk: :invalid} = a, _opts), do: {:error, {:conflict, a}}
  defp risk_gate(%Analysis{risk: :conflict} = a, _opts), do: {:error, {:conflict, a}}

  defp risk_gate(%Analysis{risk: :overlap} = a, opts) do
    if Keyword.get(opts, :confirm_overlap, false),
      do: :ok,
      else: {:error, {:confirmation_required, a}}
  end

  defp risk_gate(%Analysis{risk: :clean}, _opts), do: :ok

  # patch_path is always our own write_temp_patch!/1 output (server-generated
  # unique_integer filename under System.tmp_dir!/0), never derived from ctx
  # or proposal content.
  # sobelow_skip ["Traversal.FileModule"]
  defp do_apply(root, rel_path, proposal, analysis, ctx, opts) do
    patch_path = write_temp_patch!(proposal.diff)

    try do
      with :ok <- adapter().check(root, patch_path),
           :ok <- adapter().apply(root, patch_path) do
        result = %{
          applied_files: Enum.map(proposal.changes, & &1.path),
          risk: analysis.risk,
          proposal: rel_path
        }

        audit_applied(ctx, rel_path, proposal, analysis, opts)
        {:ok, result}
      else
        {:error, reason} ->
          audit_blocked(ctx, rel_path, "proposal.apply_failed", :git_error, %{
            "detail" => inspect(reason)
          })

          {:error, {:git_error, reason}}
      end
    after
      File.rm(patch_path)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_temp_patch!(diff) do
    path =
      Path.join(System.tmp_dir!(), "devide-proposal-#{:erlang.unique_integer([:positive])}.patch")

    File.write!(path, diff)
    File.chmod(path, 0o600)
    path
  end

  defp audit_applied(ctx, rel_path, proposal, analysis, opts) do
    Audit.emit!(%{
      action: "proposal.applied",
      workspace_id: Map.get(ctx, :workspace_id),
      actor_id: Map.get(ctx, :actor_id),
      target_type: "proposal",
      target_ref: rel_path,
      decision: :allow,
      metadata: %{
        "risk" => Atom.to_string(analysis.risk),
        "confirmed_overlap" => Keyword.get(opts, :confirm_overlap, false),
        "files_count" => length(proposal.changes),
        "files" => proposal.changes |> Enum.map(& &1.path) |> Enum.take(20),
        "diff_sha256" => diff_digest(proposal.diff)
      }
    })
  end

  defp audit_blocked(ctx, rel_path, action, reason, extra_metadata) do
    Audit.emit!(%{
      action: action,
      workspace_id: Map.get(ctx, :workspace_id),
      actor_id: Map.get(ctx, :actor_id),
      target_type: "proposal",
      target_ref: rel_path,
      decision: :deny,
      reason: reason,
      metadata: extra_metadata
    })
  end

  defp diff_digest(diff) do
    :crypto.hash(:sha256, diff) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp adapter,
    do: Application.get_env(:dev_ide, :proposal_apply_adapter, DevIDE.ProposalApply.GitAdapter)
end
