defmodule Casein.Agents.JidoWorkcell.ReceiptTest do
  use ExUnit.Case, async: true

  alias Casein.Agents.JidoWorkcell.{Limits, OwnerRef, Receipt}
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

  test "builds the frozen Gate 0 Casein waiting shape", %{scope: scope} do
    {:ok, receipt} = Receipt.build(scope, git_result(), attrs(scope))

    assert Map.keys(receipt) |> Enum.sort() ==
             [
               :authorization,
               :contract,
               :evidence_ref,
               :files,
               :git,
               :handoff_id,
               :idempotency,
               :owner_ref,
               :receipt_id,
               :request_id,
               :runtime_id,
               :schema_version,
               :session_id,
               :source,
               :tests,
               :workcell_id,
               :worker_id,
               :workspace_id
             ]

    assert receipt.schema_version == 1
    assert receipt.contract == %{name: "casein-dash-handoff", version: "1.0"}
    assert receipt.source == "casein_worker"
    assert receipt.request_id == "request-gate0"
    assert receipt.session_id == "session-gate0"
    assert receipt.workcell_id == "workcell-gate0"
    assert receipt.owner_ref == scope.owner_ref
    assert receipt.authorization == %{decision: "allow", decision_id: "decision-gate0"}
    assert receipt.files == [%{path: "README.md"}]

    assert receipt.git == %{
             repository: "dl-alexandre/casein",
             base_branch: "master",
             head_branch: "agent/gate0-receipt",
             head_sha: @head_sha,
             release_sha: @release_sha,
             pr_number: nil,
             pr_url: nil,
             outcome: "waiting",
             merged_sha: nil,
             merge_actor_ref: nil,
             post_merge_evidence_ref: nil
           }

    assert receipt.idempotency == %{
             handoff_key: Receipt.idempotency_key(receipt.handoff_id, @head_sha)
           }

    refute Map.has_key?(receipt, :kind)
    refute Map.has_key?(receipt, :redaction)
    refute Map.has_key?(receipt, :occurred_at)
    refute Map.has_key?(receipt, :changed_files)
    refute Map.has_key?(receipt, :idempotency_key)
    refute Map.has_key?(receipt.git, :pushed)
    refute Map.has_key?(receipt, :task_id)
    refute Map.has_key?(receipt, :lease_id)
    refute Map.has_key?(receipt, :correlation_id)

    assert Receipt.validate(
             Map.update!(receipt, :idempotency, fn _ ->
               %{
                 handoff_key:
                   Receipt.review_thread_action_key(
                     receipt.handoff_id,
                     @head_sha,
                     "thread-opaque-1"
                   )
               }
             end)
           ) == {:error, :idempotency_namespace_mismatch}

    assert Receipt.validate(receipt) == :ok
    assert Receipt.valid_public?(receipt)
    assert receipt |> Jason.encode!() |> Jason.decode!() |> Receipt.validate() == :ok

    action_key =
      Receipt.review_thread_action_key(receipt.handoff_id, @head_sha, "thread-opaque-1")

    assert action_key == "review-thread:v1:#{receipt.handoff_id}:#{@head_sha}:thread-opaque-1"
    refute action_key == receipt.idempotency.handoff_key
  end

  test "rejects old producer aliases and unknown fields", %{scope: scope} do
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

    receipt = build_waiting!(scope)

    assert Receipt.validate(Map.put(receipt, :merged_sha, @merged_sha)) ==
             {:error, :forbidden_alias}

    assert Receipt.validate(Map.put(receipt, :idempotency_key, "legacy")) ==
             {:error, :forbidden_alias}

    assert Receipt.validate(Map.update!(receipt, :git, &Map.put(&1, :pushed, true))) ==
             {:error, :forbidden_alias}
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

  test "session and workcell IDs are required and Mira IDs remain conditional", %{scope: scope} do
    assert {:error, :session_id_required} =
             Receipt.build(scope, git_result(), Map.delete(attrs(scope), :session_id))

    assert {:error, :workcell_not_assigned} =
             Receipt.build(scope, git_result(), Map.put(attrs(scope), :workcell_assigned?, false))

    {:ok, terminal} =
      Receipt.build(
        scope,
        git_result(),
        attrs(scope) |> Map.merge(%{source: "v3_casein", lane: "casein_terminal"})
      )

    assert terminal.source == "v3_casein"
    refute Map.has_key?(terminal, :task_id)

    task_id = Ecto.UUID.generate()

    {:ok, mira} =
      Receipt.build(
        scope,
        git_result(),
        Map.merge(attrs(scope), %{
          origin: "mira",
          task_id: task_id,
          lease_id: "lease-gate0",
          correlation_id: task_id
        })
      )

    assert mira.task_id == task_id
    assert mira.lease_id == "lease-gate0"
    assert mira.correlation_id == task_id
    assert Receipt.validate(mira) == :ok

    assert {:error, :illegal_origin_id} =
             Receipt.build(scope, git_result(), Map.put(attrs(scope), :task_id, task_id))

    assert {:error, :correlation_task_mismatch} =
             Receipt.build(
               scope,
               git_result(),
               Map.merge(attrs(scope), %{
                 origin: "mira",
                 task_id: task_id,
                 lease_id: "lease-gate0",
                 correlation_id: Ecto.UUID.generate()
               })
             )
  end

  test "authorization, files, and nested tests are fail-closed", %{scope: scope} do
    assert {:error, :authorization_decision_id_required} =
             Receipt.build(
               scope,
               git_result(),
               Map.put(attrs(scope), :authorization, %{decision: "allow"})
             )

    assert {:error, :invalid_authorization_decision} =
             Receipt.build(
               scope,
               git_result(),
               Map.put(attrs(scope), :authorization, %{
                 decision: "approve",
                 decision_id: "decision-gate0"
               })
             )

    assert {:error, :test_name_alias_not_allowed} =
             Receipt.build(
               scope,
               git_result(),
               Map.put(attrs(scope), :tests, [%{command: "mix test", name: "legacy"}])
             )

    assert {:error, :commit_sha_not_allowed} =
             Receipt.build(
               scope,
               git_result(),
               Map.put(attrs(scope), :tests, [%{command: "mix test", commit_sha: @head_sha}])
             )

    assert {:error, :absolute_path} =
             Receipt.build(
               scope,
               Map.put(git_result(), :changed_files, ["/etc/passwd"]),
               attrs(scope)
             )

    assert {:error, :unknown_field} =
             Receipt.build(scope, git_result(), Map.put(attrs(scope), :blocker, "not on Gate 0"))
  end

  test "validates a Dash merged document without allowing Casein to produce it", %{scope: scope} do
    waiting = build_waiting!(scope)

    merged =
      waiting
      |> Map.put(:source, "dash_verda")
      |> Map.put(:git, %{
        waiting.git
        | outcome: "merged",
          pr_number: 1065,
          pr_url: "https://github.com/dl-alexandre/casein/pull/1065",
          merged_sha: @merged_sha,
          merge_actor_ref: "github_app/dash-bot",
          post_merge_evidence_ref: "pipeline-1065"
      })

    assert Receipt.validate(merged) == :ok
    assert Receipt.valid_public?(merged)

    assert Receipt.validate(
             Map.update!(merged, :git, &Map.put(&1, :head_sha, @merged_sha)),
             %{repository: "dl-alexandre/casein", pr_number: 1065, head_sha: @head_sha}
           ) == {:error, :invalid_dash_identity}

    assert Receipt.validate(Map.put(merged, :schema_version, "gate0.v1")) ==
             {:error, :schema_version_unsupported}

    assert Receipt.validate(Map.put(merged, :git, %{merged.git | merged_sha: nil})) ==
             {:error, :merged_sha_required}
  end

  test "keeps the protocol boundary at the frozen 8192-byte limit" do
    assert Limits.input_max_bytes() == 8_192
    assert {:error, :input_too_large} = Limits.validate_input(String.duplicate("x", 8_193))
  end

  defp git_result, do: %{head_sha: @head_sha, changed_files: ["README.md"], pushed?: true}

  defp attrs(_scope) do
    %{
      source: "casein_worker",
      request_id: "request-gate0",
      session_id: "session-gate0",
      workcell_id: "workcell-gate0",
      workcell_assigned?: true,
      authorization: %{decision: "allow", decision_id: "decision-gate0"},
      evidence_ref: "evidence-gate0",
      handoff_id: "handoff-gate0",
      receipt_id: "receipt-gate0",
      tests: [%{command: "mix test", status: "passed"}]
    }
  end

  defp build_waiting!(scope) do
    {:ok, receipt} = Receipt.build(scope, git_result(), attrs(scope))
    receipt
  end
end
