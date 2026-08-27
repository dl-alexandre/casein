defmodule Casein.Agents.JidoWorkcellLifecycleTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.{JidoPod, JidoRuntime, JidoWorkcell}
  alias Casein.Agents.JidoWorkcell.{Receipt, ResourceStore}
  alias Casein.Agents.JidoWorkcell.Git.Scope
  alias Casein.Test.Eventually

  @release_sha String.duplicate("b", 40)
  @head_sha String.duplicate("a", 40)

  setup do
    previous = %{
      enabled: Application.get_env(:casein, :casein_enabled),
      headless: Application.get_env(:casein, :jido_headless),
      workspaces: Application.get_env(:casein, :jido_headless_workspaces),
      pod: Application.get_env(:casein, :jido_pod),
      workcell: Application.get_env(:casein, :jido_workcell),
      runner: Application.get_env(:casein, :jido_code_actions),
      git_adapter: Application.get_env(:casein, :jido_workcell_git_adapter),
      casein_env: System.get_env("CASEIN_ENABLED")
    }

    Application.put_env(:casein, :casein_enabled, true)
    Application.put_env(:casein, :jido_headless, true)
    Application.put_env(:casein, :jido_headless_workspaces, %{})
    Application.put_env(:casein, :jido_workcell, idle_timeout_ms: :infinity, lease_ttl_ms: 1_000)
    Application.put_env(:casein, :jido_code_actions, fn _name, args, _ctx -> {:ok, args} end)
    :ok = ResourceStore.reset()

    on_exit(fn ->
      Registry.select(Casein.Agents.JidoWorkcell.Registry, [
        {{:"$1", :_, :_}, [], [:"$1"]}
      ])
      |> Enum.each(fn workcell_id ->
        if pid = Casein.Agents.JidoWorkcell.Cell.whereis(workcell_id),
          do:
            DynamicSupervisor.terminate_child(
              Casein.Agents.JidoWorkcell.CellSupervisor,
              pid
            )
      end)

      Registry.select(Casein.Agents.JidoPod.Registry, [
        {{{:pod, :"$1"}, :_, :_}, [], [:"$1"]}
      ])
      |> Enum.each(&JidoPod.stop_pod/1)

      _ = ResourceStore.reset()
      restore(:casein_enabled, previous.enabled)
      restore(:jido_headless, previous.headless)
      restore(:jido_headless_workspaces, previous.workspaces)
      restore(:jido_pod, previous.pod)
      restore(:jido_workcell, previous.workcell)
      restore(:jido_code_actions, previous.runner)
      restore(:jido_workcell_git_adapter, previous.git_adapter)
      restore_env("CASEIN_ENABLED", previous.casein_env)
    end)

    :ok
  end

  test "provisions one ready resource and binds one worker" do
    workspace_id = workspace("one")

    assert {:ok, resource} = JidoWorkcell.provision(workspace_id, idle_timeout_ms: :infinity)
    assert resource.ready?
    assert resource.healthy?
    assert resource.state == :ready
    assert resource.runtime == "jido"
    assert resource.provider == "opencode"
    assert resource.model == "opencode/grok-4.6"

    assert {:ok, worker} = JidoWorkcell.admit(workspace_id, %{runtime: :jido, actions: []})
    assert worker.workcell_id == resource.workcell_id
    assert {:ok, %{state: :completed}} = JidoWorkcell.await(workspace_id, worker.worker_id)

    assert {:ok, health} = JidoWorkcell.health(workspace_id)
    assert health.worker_count == 1
    assert health.worker_ids == [worker.worker_id]
    assert health.lease_count == 0
  end

  test "idle teardown stops an empty cell and retains stopped health" do
    workspace_id = workspace("idle")
    workcell_id = JidoWorkcell.workcell_id(workspace_id)

    assert {:ok, resource} = JidoWorkcell.provision(workspace_id, idle_timeout_ms: 20)
    assert resource.ready?

    assert {:ok, _stopped} =
             Eventually.await(
               fn ->
                 case Casein.Agents.JidoWorkcell.Cell.whereis(workcell_id) do
                   nil -> {:ok, :stopped}
                   _pid -> false
                 end
               end,
               timeout_ms: 1_000,
               message: "idle Workcell did not tear down"
             )

    assert {:ok, health} = JidoWorkcell.health(workspace_id)
    assert health.state == :stopped
    refute health.ready?
    refute health.healthy?
  end

  test "rollback cancels active workers and preserves rollback health" do
    workspace_id = workspace("rollback")
    parent = self()

    Application.put_env(:casein, :jido_code_actions, fn _name, _args, _ctx ->
      send(parent, :rollback_worker_started)

      receive do
        :release -> {:ok, %{released: true}}
      end
    end)

    assert {:ok, _worker} =
             JidoWorkcell.admit(workspace_id, %{
               actions: [%{name: "code_read", args: %{}}]
             })

    assert_receive :rollback_worker_started, 1_000
    assert {:ok, rolled_back} = JidoWorkcell.rollback(workspace_id, :provision_failed)
    assert rolled_back.rollback?
    assert rolled_back.state == :stopped

    assert {:ok, health} = JidoWorkcell.health(workspace_id)
    assert health.state == :stopped
    assert health.rollback_reason == :provision_failed
    assert health.active_worker_count == 0
    assert Casein.Agents.JidoWorkcell.Cell.whereis(JidoWorkcell.workcell_id(workspace_id)) == nil
  end

  test "one Workcell can bind multiple distinct Jido workers" do
    workspace_id = workspace("many")

    assert {:ok, first} = JidoWorkcell.admit(workspace_id, %{actions: []})
    assert {:ok, second} = JidoWorkcell.admit(workspace_id, %{actions: []})
    assert first.workcell_id == second.workcell_id
    refute first.worker_id == second.worker_id
    refute first.runtime_id == second.runtime_id

    assert {:ok, _} = JidoWorkcell.await(workspace_id, first.worker_id)
    assert {:ok, _} = JidoWorkcell.await(workspace_id, second.worker_id)

    assert {:ok, health} = JidoWorkcell.health(workspace_id)
    assert health.worker_count == 2
    assert Enum.sort(health.worker_ids) == Enum.sort([first.worker_id, second.worker_id])
  end

  test "the Workcell owns one runtime and worker identity per admitted process" do
    workspace_id = workspace("identity")

    assert {:ok, worker} =
             JidoWorkcell.admit(workspace_id, %{
               runtime_id: "runtime-spoofed",
               worker_id: "worker-spoofed",
               actions: []
             })

    refute worker.runtime_id == "runtime-spoofed"
    refute worker.worker_id == "worker-spoofed"
    assert worker.runtime_id =~ ~r/\Aruntime-[a-f0-9]{32}\z/
    assert worker.worker_id =~ ~r/\Aworker-[a-f0-9]{32}\z/
  end

  test "lease expiry cancels a worker and releases the Workcell lease" do
    workspace_id = workspace("lease")
    parent = self()

    Application.put_env(:casein, :jido_code_actions, fn _name, _args, ctx ->
      send(parent, {:started, ctx.worker_id})

      receive do
        :release -> {:ok, %{released: true}}
      end
    end)

    assert {:ok, worker} =
             JidoWorkcell.admit(workspace_id, %{
               lease_ttl_ms: 25,
               actions: [%{name: "code_read", args: %{}}]
             })

    worker_id = worker.worker_id
    assert_receive {:started, ^worker_id}, 1_000

    assert {:ok, cancelled} =
             Eventually.await(
               fn ->
                 case JidoWorkcell.status(workspace_id, worker.worker_id) do
                   {:ok, %{state: :cancelled} = attempt} -> {:ok, attempt}
                   _ -> false
                 end
               end,
               timeout_ms: 2_000,
               message: "lease did not expire"
             )

    assert cancelled.state == :cancelled
    assert {:ok, health} = JidoWorkcell.health(workspace_id)
    assert health.lease_count == 0
    assert health.active_worker_count == 0
  end

  test "cancellation and drain stop new admission while active work finishes" do
    workspace_id = workspace("drain")
    parent = self()

    gate =
      start_supervised!({Agent, fn -> MapSet.new() end}, id: {:jido_workcell_gate, unique_id()})

    put_pod_limits(max_running_per_workspace: 1, max_queued_per_workspace: 2)

    Application.put_env(:casein, :jido_code_actions, fn _name, args, _ctx ->
      token = args[:token] || args["token"]
      send(parent, {:jido_workcell_noop, token})

      Eventually.await(
        fn ->
          if Agent.get(gate, &MapSet.member?(&1, token)), do: {:ok, %{token: token}}, else: false
        end,
        timeout_ms: 5_000
      )
    end)

    assert {:ok, running} =
             JidoWorkcell.admit(workspace_id, %{
               actions: [%{name: "code_read", args: %{token: "run"}}]
             })

    assert_receive {:jido_workcell_noop, "run"}, 1_000

    assert {:ok, queued} =
             JidoWorkcell.admit(workspace_id, %{
               actions: [%{name: "code_read", args: %{token: "queued"}}]
             })

    assert queued.state == :queued
    assert {:ok, _} = JidoWorkcell.cancel(workspace_id, queued.worker_id)
    assert {:ok, %{state: :cancelled}} = JidoWorkcell.await(workspace_id, queued.worker_id)

    assert {:ok, []} = JidoWorkcell.drain(workspace_id)
    assert {:error, :draining} = JidoWorkcell.admit(workspace_id, %{actions: []})

    Agent.update(gate, &MapSet.put(&1, "run"))
    assert {:ok, %{state: :completed}} = JidoWorkcell.await(workspace_id, running.worker_id)
    assert {:ok, health} = JidoWorkcell.health(workspace_id)
    assert health.state == :draining
    assert health.ready? == false
  end

  test "a retryable worker failure retries within the same Workcell" do
    workspace_id = workspace("retry")
    counter = start_supervised!({Agent, fn -> 0 end}, id: {:jido_workcell_retry, unique_id()})

    Application.put_env(:casein, :jido_code_actions, fn _name, _args, _ctx ->
      Agent.get_and_update(counter, fn
        0 -> {{:error, :timeout}, 1}
        count -> {{:ok, %{status: "completed", attempt: count}}, count + 1}
      end)
    end)

    assert {:ok, worker} =
             JidoWorkcell.admit(workspace_id, %{
               max_retries: 1,
               actions: [%{name: "code_read", args: %{}}]
             })

    assert {:ok, completed} = JidoWorkcell.await(workspace_id, worker.worker_id)
    assert completed.state == :completed
    assert completed.retries == 1
    assert completed.next_index == 1
  end

  test "completion emits a strict Casein waiting receipt and never a merged receipt" do
    workspace_id = workspace("receipt")
    worktree = Path.join(System.tmp_dir!(), "jido-workcell-receipt-#{unique_id()}")
    File.mkdir_p!(worktree)

    Application.put_env(
      :casein,
      :jido_workcell_git_adapter,
      Casein.Agents.JidoWorkcellLifecycleTest.FakeGitAdapter
    )

    scope = %Scope{
      repository: "dl-alexandre/casein",
      worktree_path: worktree,
      base_branch: "master",
      assigned_branch: "agent/jido-receipt",
      default_branch: "master",
      workspace_id: workspace_id,
      owner_ref: %{provider: "github", id: "dl-alexandre", role: "operator"},
      runtime_id: "runtime-scope",
      worker_id: "worker-scope",
      release_sha: @release_sha,
      allowed_paths: ["README.md"],
      protected_branches: ["master", "main"],
      worktree_root: worktree,
      push_allowed?: true
    }

    attrs = %{
      session_id: "session-receipt",
      request_id: "request-receipt",
      receipt_id: "receipt-receipt",
      authorization: %{decision: "allow", decision_id: "decision-receipt"},
      owner_ref: scope.owner_ref,
      release_sha: @release_sha,
      git_scope: scope,
      actions: [
        %{
          name: "git_handoff",
          args: %{
            receipt_id: "receipt-receipt",
            handoff_id: "handoff-receipt",
            message: "test audited handoff",
            paths: ["README.md"],
            tests: [%{command: "mix test", status: "passed"}]
          }
        }
      ]
    }

    assert {:ok, worker} = JidoWorkcell.admit(workspace_id, attrs)
    assert {:ok, completed} = JidoWorkcell.await(workspace_id, worker.worker_id)
    assert completed.state == :completed
    assert %{completion_receipt: receipt} = completed
    assert receipt.source == "casein_worker"
    assert receipt.git.outcome == "waiting"
    assert receipt.git.head_sha == @head_sha
    assert receipt.git.merged_sha == nil
    assert Receipt.validate(receipt) == :ok
    refute Map.has_key?(receipt.git, :pr_number)
    refute Map.has_key?(receipt.git, :pr_url)
    refute Map.has_key?(receipt, :task_id)
    refute Map.has_key?(receipt, :lease_id)
    refute Map.has_key?(receipt, :correlation_id)

    File.rm_rf!(worktree)
  end

  test "CASEIN_ENABLED=false selects the fallback and starts no Workcell" do
    workspace_id = workspace("disabled")
    System.put_env("CASEIN_ENABLED", "false")

    assert JidoPod.select_runtime(workspace_id) == :opencode
    assert {:error, :casein_disabled} = JidoWorkcell.provision(workspace_id)
    assert {:ok, fallback} = JidoWorkcell.admit(workspace_id, %{actions: []})
    assert fallback.fallback?
    assert fallback.reason == :casein_disabled
    assert Casein.Agents.JidoWorkcell.Cell.whereis(JidoWorkcell.workcell_id(workspace_id)) == nil
  end

  test "runtime and launcher profiles keep Jido separate from the OpenCode executable" do
    assert JidoRuntime.profile() == %{
             runtime: "jido",
             runtime_name: "jido",
             provider: "opencode",
             model: "opencode/grok-4.6",
             api_model: "grok-4.6",
             launcher: nil,
             headless: true
           }

    assert {:ok, jido} = Casein.Desktop.AgentLauncher.runtime_profile("jido")
    assert jido.launchable? == false
    assert jido.headless == true

    assert {:ok, opencode} = Casein.Desktop.AgentLauncher.runtime_profile("opencode")
    assert opencode.launchable? == true
    assert opencode.provider == "opencode"
    assert opencode.model == "opencode/grok-4.6"

    assert {:error, :legacy_opencode} =
             JidoWorkcell.provision(workspace("opencode"), runtime: :opencode)
  end

  defmodule FakeGitAdapter do
    @behaviour Casein.Agents.JidoWorkcell.Git.Adapter

    @impl true
    def bind(scope), do: {:ok, scope}

    @impl true
    def status(_scope), do: {:ok, %{}}

    @impl true
    def diff(_scope, _paths), do: {:ok, %{}}

    @impl true
    def stage(_scope, paths), do: {:ok, %{paths: paths}}

    @impl true
    def commit(_scope, attrs),
      do: {:ok, %{head_sha: String.duplicate("a", 40), changed_files: attrs[:paths]}}

    @impl true
    def push(_scope), do: {:ok, %{pushed?: true}}

    @impl true
    def head_sha(_scope), do: {:ok, String.duplicate("a", 40)}
  end

  defp workspace(prefix), do: "ws-workcell-#{prefix}-#{unique_id()}"
  defp unique_id, do: System.unique_integer([:positive])

  defp put_pod_limits(overrides) do
    current = Application.get_env(:casein, :jido_pod, [])
    Application.put_env(:casein, :jido_pod, Keyword.merge(current, overrides))
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
