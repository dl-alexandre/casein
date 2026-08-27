defmodule Casein.Agents.JidoWorkcell.ResourceStoreTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.JidoWorkcell.{Receipt, ResourceStore}
  alias Casein.Agents.JidoWorkcell.Git.Ledger
  alias Casein.Agents.JidoWorkcell.Git.Scope
  alias Casein.Runtimes.MemoryAdapter
  alias Casein.Test.Eventually

  @head_sha String.duplicate("a", 40)
  @release_sha String.duplicate("b", 40)
  @other_head_sha String.duplicate("c", 40)

  setup do
    previous_adapter = Application.get_env(:casein, :runtimes_adapter)
    Application.put_env(:casein, :runtimes_adapter, MemoryAdapter)
    ResourceStore.reset()

    on_exit(fn ->
      restore(:runtimes_adapter, previous_adapter)
      ResourceStore.reset()
    end)

    :ok
  end

  test "persists an allowlisted projection and retires process state on recovery" do
    workcell_id = "workcell-recovery-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    resource = %{
      workcell_id: workcell_id,
      workspace_id: "ws-recovery-#{System.unique_integer([:positive])}",
      state: :active,
      actual_state: :active,
      desired_state: :active,
      ready?: true,
      readiness: :ready,
      healthy?: true,
      runtime: "jido",
      runtime_name: "jido",
      provider: "opencode",
      model: "opencode/grok-4.6",
      api_model: "grok-4.6",
      headless: true,
      worker_ids: ["worker-recovery"],
      worker_count: 1,
      active_worker_count: 1,
      leases: [
        %{
          lease_id: "lease-recovery",
          attempt_id: "attempt-recovery",
          worker_id: "worker-recovery",
          expires_at: DateTime.add(now, 60, :second)
        }
      ],
      created_at: now,
      last_used_at: now,
      updated_at: now,
      last_health: %{ready?: true, healthy?: true, observed_at: now},
      credentials: "do-not-store",
      token: "do-not-store"
    }

    assert :ok = ResourceStore.put(workcell_id, resource)
    assert {:ok, runtime} = MemoryAdapter.get_runtime(workcell_id)
    assert runtime.isolation_mode == "jido_workcell"
    assert runtime.metadata["kind"] == "casein_jido_workcell"

    persisted = runtime.metadata["resource"]
    assert persisted["workcell_id"] == workcell_id
    assert persisted["actual_state"] == "active"
    assert persisted["desired_state"] == "active"
    assert persisted["health"]["headless"]
    refute Map.has_key?(persisted, "credentials")
    refute Map.has_key?(persisted, "token")
    refute Jason.encode!(runtime.metadata) =~ "do-not-store"
    refute Map.has_key?(ResourceStore.get(workcell_id), :credentials)
    refute Map.has_key?(ResourceStore.get(workcell_id), :token)

    assert :ok = ResourceStore.reset()
    assert :ok = ResourceStore.recover()
    recovered = ResourceStore.get(workcell_id)

    assert recovered.state == :stopped
    assert recovered.actual_state == :stopped
    assert recovered.desired_state == :active
    assert recovered.ready? == false
    assert recovered.healthy? == false
    assert recovered.leases == []
    assert recovered.recovery.status == :retired
    assert recovered.recovery.reason == :application_restart
    assert recovered.recovery.stale_lease_ids == ["lease-recovery"]

    assert {:ok, runtime_after} = MemoryAdapter.get_runtime(workcell_id)
    assert runtime_after.status == "cleaned"
    assert runtime_after.metadata["resource"]["actual_state"] == "stopped"
    assert runtime_after.metadata["resource"]["recovery"]["reason"] == "application_restart"
  end

  test "replays a persisted handoff after the catalog and ledger restart" do
    workcell_id = "workcell-idempotency-#{System.unique_integer([:positive])}"
    workspace_id = "ws-idempotency-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    assert :ok =
             ResourceStore.put(workcell_id, %{
               workcell_id: workcell_id,
               workspace_id: workspace_id,
               state: :ready,
               desired_state: :ready,
               ready?: true,
               readiness: :ready,
               healthy?: true,
               runtime: "jido",
               runtime_name: "jido",
               provider: "opencode",
               model: "opencode/grok-4.6",
               api_model: "grok-4.6",
               headless: true,
               created_at: now,
               updated_at: now
             })

    scope = %Scope{
      repository: "dl-alexandre/casein",
      worktree_path: System.tmp_dir!(),
      base_branch: "master",
      assigned_branch: "agent/restart-idempotency",
      default_branch: "master",
      workspace_id: workspace_id,
      owner_ref: %{provider: "github", id: "dl-alexandre", role: "operator"},
      runtime_id: "runtime-restart-idempotency",
      worker_id: "worker-restart-idempotency",
      release_sha: @release_sha,
      allowed_paths: ["README.md"],
      protected_branches: ["master", "main"],
      worktree_root: System.tmp_dir!(),
      push_allowed?: true
    }

    attrs = %{
      source: "casein_worker",
      request_id: "request-restart-idempotency",
      session_id: "session-restart-idempotency",
      workcell_id: workcell_id,
      workcell_assigned?: true,
      authorization: %{decision: "allow", decision_id: "decision-restart-idempotency"},
      handoff_id: "handoff-restart-idempotency",
      receipt_id: "receipt-restart-idempotency",
      tests: [%{command: "mix test", status: "passed"}]
    }

    assert {:ok, receipt} =
             Receipt.build(
               scope,
               %{head_sha: @head_sha, changed_files: ["README.md"], pushed?: true},
               attrs
             )

    fingerprint = :crypto.hash(:sha256, "restart-idempotency")
    handoff_id = attrs.handoff_id

    assert {:ok, ^receipt} =
             Ledger.run(handoff_id, fingerprint, nil, workcell_id, fn -> {:ok, receipt} end)

    assert ResourceStore.get(workcell_id).idempotency[handoff_id].head_sha == @head_sha
    assert :ok = ResourceStore.reset()
    assert :ok = ResourceStore.recover()

    old_pid = Process.whereis(Ledger)
    assert is_pid(old_pid)
    :ok = GenServer.stop(old_pid)

    assert {:ok, new_pid} =
             Eventually.await(
               fn ->
                 case Process.whereis(Ledger) do
                   pid when is_pid(pid) and pid != old_pid -> {:ok, pid}
                   _ -> false
                 end
               end,
               timeout_ms: 2_000,
               message: "handoff ledger did not restart"
             )

    assert is_pid(new_pid)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    assert {:ok, replayed} =
             Ledger.run(handoff_id, fingerprint, nil, workcell_id, fn ->
               Agent.update(counter, &(&1 + 1))
               {:ok, receipt}
             end)

    assert replayed == receipt
    assert Agent.get(counter, & &1) == 0

    assert {:error, :reused_handoff_new_sha} =
             Ledger.run(handoff_id, fingerprint, @other_head_sha, workcell_id, fn ->
               {:ok, receipt}
             end)
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
