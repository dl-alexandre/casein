defmodule Casein.Agents.JidoWorkcell.ReceiptTest do
  use ExUnit.Case, async: true

  alias Casein.Agents.JidoWorkcell.{OwnerRef, Receipt}
  alias Casein.Agents.JidoWorkcell.Git.Scope

  @head_sha String.duplicate("a", 40)
  @other_head_sha String.duplicate("c", 40)
  @merged_sha String.duplicate("d", 40)
  @release_sha String.duplicate("b", 40)

  setup do
    worktree =
      Path.join(System.tmp_dir!(), "casein-gate0-receipt-#{System.unique_integer([:positive])}")

    File.mkdir_p!(worktree)

    owner_ref = %{provider: "github", id: "dl-alexandre", role: "operator"}

    scope = %Scope{
      repository: "dl-alexandre/casein",
      worktree_path: worktree,
      base_branch: "master",
      assigned_branch: "agent/gate0-receipt",
      default_branch: "master",
      workspace_id: "ws-gate0-receipt",
      owner_ref: owner_ref,
      runtime_id: "runtime-gate0",
      worker_id: "worker-gate0",
      release_sha: @release_sha,
      allowed_paths: ["README.md", "docs/gate0.md"],
      protected_branches: ["master", "main"],
      worktree_root: worktree,
      push_allowed?: true
    }

    on_exit(fn -> File.rm_rf!(worktree) end)
    %{scope: scope}
  end

  test "builds and validates a canonical Casein waiting receipt", %{scope: scope} do
    {:ok, receipt} = Receipt.build(scope, git_result(), attrs(scope))

    assert receipt.schema_version == 1
    assert receipt.contract == %{name: "casein-dash-handoff", version: "1.0"}
    assert receipt.source == "casein_worker"
    assert receipt.owner_ref == scope.owner_ref
    assert receipt.head_sha == @head_sha
    assert receipt.release_sha == @release_sha
    assert receipt.git == %{outcome: "waiting", pushed: true, merged_sha: nil}
    refute Map.has_key?(receipt, :merged_sha)
    refute Map.has_key?(receipt, :task_id)
    refute Map.has_key?(receipt, :lease_id)
    refute Map.has_key?(receipt, :correlation_id)
    assert receipt.idempotency_key == Receipt.idempotency_key(receipt.handoff_id, @head_sha)
    assert Receipt.validate(receipt) == :ok
    assert Receipt.valid_public?(receipt)

    assert receipt |> Jason.encode!() |> Jason.decode!() |> Receipt.validate() == :ok

    assert Receipt.review_thread_action_key(receipt.handoff_id, @head_sha, "thread-opaque-1") ==
             "review-thread:v1:#{receipt.handoff_id}:#{@head_sha}:thread-opaque-1"

    refute Receipt.review_thread_action_key(receipt.handoff_id, @head_sha, "thread-opaque-1") ==
             receipt.idempotency_key
  end

  test "rejects legacy aliases and unknown fields instead of normalizing them", %{scope: scope} do
    assert {:error, :commit_sha_not_allowed} =
             Receipt.build(scope, Map.put(git_result(), :commit_sha, @head_sha), attrs(scope))

    assert {:error, :commit_sha_not_allowed} =
             Receipt.build(scope, git_result(), Map.put(attrs(scope), :commit_sha, @head_sha))

    assert {:error, :test_name_alias_not_allowed} =
             Receipt.build(
               scope,
               git_result(),
               Map.put(attrs(scope), :tests, [%{name: "mix test"}])
             )

    assert {:error, :unknown_field} =
             Receipt.build(scope, git_result(), Map.put(attrs(scope), :oban_job_id, "oban-1"))

    assert {:error, :unknown_field} =
             Receipt.build(scope, git_result(), Map.put(attrs(scope), :merged_sha, @merged_sha))

    malformed = Map.put(build_waiting!(scope), :merged_sha, @merged_sha)
    assert Receipt.validate(malformed) == {:error, :unknown_field}
  end

  test "requires exact lowercase SHAs and a structured owner reference", %{scope: scope} do
    assert {:error, :invalid_head_sha} =
             Receipt.build(
               scope,
               Map.put(git_result(), :head_sha, String.upcase(@head_sha)),
               attrs(scope)
             )

    bad_release = %{scope | release_sha: String.upcase(@release_sha)}
    assert {:error, :invalid_release_sha} = Receipt.build(bad_release, git_result(), attrs(scope))

    bad_owner = %{scope | owner_ref: "alexandre@example.com"}
    assert {:error, :invalid_owner_ref} = Receipt.build(bad_owner, git_result(), attrs(scope))

    assert {:error, :owner_ref_email_not_allowed} =
             OwnerRef.normalize(%{
               provider: "email",
               id: "alexandre@example.com",
               role: "operator"
             })

    assert {:error, :invalid_owner_ref_id} =
             OwnerRef.normalize(%{provider: "github", id: "not/a/scalar", role: "operator"})
  end

  test "static identity drift is not reported as a live head change", %{scope: scope} do
    assert {:error, :identity_mismatch} =
             Receipt.build(scope, git_result(), Map.put(attrs(scope), :head_sha, @other_head_sha))
  end

  test "rejects a Git result from a different branch as static identity drift", %{scope: scope} do
    assert {:error, :identity_mismatch} =
             Receipt.build(
               scope,
               Map.put(git_result(), :branch, "agent/another-branch"),
               attrs(scope)
             )
  end

  test "Casein cannot emit Dash PR or merge fields", %{scope: scope} do
    assert {:error, :invalid_source} =
             Receipt.build(
               scope,
               git_result(),
               Map.put(attrs(scope), :source, "v3_casein/casein_worker")
             )

    assert {:error, :dash_source_not_allowed} =
             Receipt.build(scope, git_result(), Map.put(attrs(scope), :source, "dash_verda"))

    assert {:error, :dash_git_fields_forbidden} =
             Receipt.build(scope, Map.put(git_result(), :pr_number, 1065), attrs(scope))

    assert {:error, :worker_merge_forbidden} =
             Receipt.build(scope, Map.put(git_result(), :outcome, "merged"), attrs(scope))

    assert {:error, :worker_merge_forbidden} =
             Receipt.build(scope, Map.put(git_result(), :merged_sha, @merged_sha), attrs(scope))

    assert {:error, :head_sha_changed_not_static} =
             Receipt.build(
               scope,
               Map.put(git_result(), :outcome, "head_sha_changed"),
               attrs(scope)
             )
  end

  test "conditional fields are emitted only for their owning lane", %{scope: scope} do
    assert {:error, :illegal_conditional_id} =
             Receipt.build(scope, git_result(), Map.put(attrs(scope), :session_id, "session-1"))

    {:ok, terminal} =
      Receipt.build(
        scope,
        git_result(),
        attrs(scope)
        |> Map.merge(%{source: "v3_casein", lane: "casein_terminal", session_id: "session-1"})
      )

    assert terminal.session_id == "session-1"

    assert {:error, :workcell_not_assigned} =
             Receipt.build(scope, git_result(), Map.put(attrs(scope), :workcell_id, "workcell-1"))

    {:ok, with_workcell} =
      Receipt.build(
        scope,
        git_result(),
        attrs(scope) |> Map.merge(%{workcell_id: "workcell-1", scheduler_assigned?: true})
      )

    assert with_workcell.workcell_id == "workcell-1"

    assert {:error, :illegal_origin_id} =
             Receipt.build(scope, git_result(), Map.put(attrs(scope), :task_id, "task_mira_001"))

    assert {:error, :invalid_task_id} =
             Receipt.build(
               scope,
               git_result(),
               Map.merge(attrs(scope), %{
                 origin: "mira",
                 task_id: "task_mira_001",
                 lease_id: "lease-1"
               })
             )

    task_id = Ecto.UUID.generate()

    {:ok, mira} =
      Receipt.build(
        scope,
        git_result(),
        Map.merge(attrs(scope), %{
          origin: "mira",
          task_id: task_id,
          lease_id: "lease-1",
          correlation_id: task_id
        })
      )

    assert mira.task_id == task_id
    assert mira.lease_id == "lease-1"
    assert mira.correlation_id == task_id
    assert mira.source == "casein_worker"
    assert mira.git.outcome == "waiting"
    assert Receipt.validate(mira) == :ok

    assert {:error, :illegal_origin_id} =
             Receipt.build(
               scope,
               git_result(),
               Map.merge(attrs(scope), %{
                 source: "v3_casein",
                 origin: "mira",
                 task_id: task_id,
                 lease_id: "lease-1",
                 correlation_id: task_id
               })
             )
  end

  test "redaction and nested test aliases remain fail-closed", %{scope: scope} do
    assert {:error, :credential_material} =
             Receipt.build(scope, git_result(), Map.put(attrs(scope), :blocker, "token=secret"))

    assert {:error, :commit_sha_not_allowed} =
             Receipt.build(
               scope,
               git_result(),
               Map.put(attrs(scope), :tests, [%{command: "mix test", commit_sha: @head_sha}])
             )

    assert {:error, :invalid_artifact} =
             Receipt.build(
               scope,
               git_result(),
               Map.put(attrs(scope), :artifacts, [%{path: "/etc/passwd", kind: "log"}])
             )
  end

  test "validates a Dash merged document without allowing Casein to produce it", %{scope: scope} do
    waiting = build_waiting!(scope)

    merged =
      waiting
      |> Map.put(:source, "dash_verda")
      |> Map.put(:git, %{
        outcome: "merged",
        pushed: true,
        pr_number: 1065,
        pr_url: "https://github.com/dl-alexandre/casein/pull/1065",
        merged_sha: @merged_sha,
        merge_actor_ref: "github_app/dash-bot",
        post_merge_evidence_ref: "pipeline-1065"
      })

    assert Receipt.validate(merged) == :ok
    assert Receipt.valid_public?(merged)

    assert Receipt.validate(Map.put(merged, :schema_version, "gate0.v1")) ==
             {:error, :schema_version_unsupported}

    assert Receipt.validate(
             Map.put(merged, :git, %{outcome: "merged", pushed: true, merged_sha: nil})
           ) ==
             {:error, :merged_sha_required}
  end

  defp git_result, do: %{head_sha: @head_sha, changed_files: ["README.md"], pushed?: true}

  defp attrs(scope) do
    suffix = Integer.to_string(System.unique_integer([:positive]))

    %{
      source: "casein_worker",
      owner_ref: scope.owner_ref,
      handoff_id: "handoff-gate0-" <> suffix,
      receipt_id: "receipt-gate0-" <> suffix,
      tests: [%{command: "mix test", status: "passed"}]
    }
  end

  defp build_waiting!(scope) do
    {:ok, receipt} = Receipt.build(scope, git_result(), attrs(scope))
    receipt
  end
end
