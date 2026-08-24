defmodule Casein.Agents.JidoBudgetsTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.Activity
  alias Casein.Agents.JidoBudgets
  alias Casein.Agents.JidoBudgets.{Decision, Limits, Verdict}
  alias Casein.Agents.JidoPod
  alias Casein.Agents.JidoPod.{Fleet, Metrics}
  alias Casein.Test.Eventually

  setup do
    previous = %{
      flag: Application.get_env(:casein, :jido_headless),
      workspaces: Application.get_env(:casein, :jido_headless_workspaces),
      pod: Application.get_env(:casein, :jido_pod),
      runner: Application.get_env(:casein, :jido_code_actions),
      sampler: Application.get_env(:casein, :jido_budget_sampler)
    }

    Application.put_env(:casein, :jido_headless, true)
    Application.put_env(:casein, :jido_headless_workspaces, %{})
    Application.put_env(:casein, :jido_code_actions, fn _name, args, _ctx -> {:ok, args} end)
    Metrics.reset()
    Fleet.reset()
    JidoBudgets.reset()
    Activity.clear()

    on_exit(fn ->
      Registry.select(Casein.Agents.JidoPod.Registry, [
        {{{:pod, :"$1"}, :_, :_}, [], [:"$1"]}
      ])
      |> Enum.each(&JidoPod.stop_pod/1)

      restore(:jido_headless, previous.flag)
      restore(:jido_headless_workspaces, previous.workspaces)
      restore(:jido_pod, previous.pod)
      restore(:jido_code_actions, previous.runner)
      restore(:jido_budget_sampler, previous.sampler)
      Metrics.reset()
      Fleet.reset()
      JidoBudgets.reset()
    end)

    :ok
  end

  test "limits are documented and readable from config" do
    limits = JidoBudgets.limits()
    assert limits.max_running_per_workspace == 2
    assert limits.max_running_fleet == 8
    assert limits.max_share_per_workspace == 0.5
    assert Limits.max_workspace_share(8) == 4
  end

  test "decide queues then rejects with honest reasons" do
    assert Decision.decide(%{running: 0, queued: 0, fleet_running: 0}) == :admit

    assert Decision.decide(%{running: 2, queued: 0, fleet_running: 2}) ==
             {:queue, :workspace_limit}

    assert Decision.decide(%{running: 2, queued: 4, fleet_running: 2}) == {:reject, :queue_full}

    assert Decision.decide(%{running: 1, queued: 0, fleet_running: 8}) == {:queue, :fleet_limit}

    assert Decision.decide(%{running: 1, queued: 4, fleet_running: 8}) == {:reject, :fleet_limit}

    assert Decision.decide(%{running: 1, queued: 0, workspace_running: 4}) ==
             {:queue, :workspace_share}

    assert Decision.decide(%{running: 0, queued: 0, provider_inflight: 4}) ==
             {:queue, :provider_limit}

    assert Decision.decide(%{running: 0, queued: 0, crash_count: 6}) == {:reject, :crash_rate}
    assert Decision.decide(%{running: 0, queued: 0, leaked_leases: 1}) == {:reject, :lease_leak}

    assert Decision.decide(%{running: 0, queued: 1, rss_pressure?: true}) ==
             {:reject, :rss_pressure}

    assert Decision.decide(%{running: 0, queued: 0, cpu_pressure?: true}) ==
             {:reject, :cpu_pressure}
  end

  test "one workspace cannot consume the fleet" do
    put_limits(
      max_running_per_workspace: 4,
      max_queued_per_workspace: 4,
      max_running_fleet: 2,
      max_share_per_workspace: 0.5
    )

    a = "ws-share-a-#{id()}"
    b = "ws-share-b-#{id()}"
    gate = start_gate()
    Application.put_env(:casein, :jido_code_actions, gate_runner(gate))

    a1 = admit_blocked(a, "a1")
    a2 = admit_blocked(a, "a2")
    assert_receive {:jido_action, "a1", _}

    assert a1.state == :running or
             match?({:ok, %{state: :running}}, JidoPod.status(a, a1.attempt_id))

    assert a2.state == :queued
    assert a2.reason == :workspace_share

    b1 = admit_blocked(b, "b1")
    assert_receive {:jido_action, "b1", _}
    assert {:ok, %{state: :running}} = JidoPod.status(b, b1.attempt_id)

    release(gate, "a1")
    release(gate, "a2")
    release(gate, "b1")
  end

  test "provider concurrency queues with an honest reason" do
    put_limits(
      max_provider_inflight: 1,
      max_running_per_workspace: 2,
      max_queued_per_workspace: 2
    )

    ws = "ws-provider-#{id()}"
    gate = start_gate()
    Application.put_env(:casein, :jido_code_actions, gate_runner(gate))

    first = admit_blocked(ws, "p1")
    assert_receive {:jido_action, "p1", _}
    second = admit_blocked(ws, "p2")
    assert second.state == :queued
    assert second.reason == :provider_limit

    release(gate, "p1")
    assert {:ok, %{state: :completed}} = JidoPod.await(ws, first.attempt_id)
    assert_receive {:jido_action, "p2", _}
    release(gate, "p2")
  end

  test "per-action output over the limit fails without persisting content" do
    put_limits(max_action_output_bytes: 80)
    ws = "ws-mem-#{id()}"
    secret = "super-secret-token-#{String.duplicate("x", 200)}"

    Application.put_env(:casein, :jido_code_actions, fn _name, _args, _ctx ->
      {:ok, %{blob: secret}}
    end)

    {:ok, attempt} =
      JidoPod.admit(%{workspace_id: ws, actions: [%{name: "code_read", args: %{}}]})

    assert {:ok, %{state: :failed, error: :memory_limit}} = JidoPod.await(ws, attempt.attempt_id)

    snap = inspect(JidoBudgets.snapshot(ws))
    refute snap =~ "super-secret"
    refute snap =~ secret
  end

  test "crash rate rejects new work with an honest reason" do
    put_limits(max_crash_rate: 0)
    ws = "ws-crash-rate-#{id()}"
    JidoBudgets.crash(ws)
    JidoBudgets.crash(ws)

    assert {:error, :crash_rate} = JidoPod.admit(%{workspace_id: ws, actions: []})
    assert %{action: :reject, reason: :crash_rate} = JidoBudgets.last_decision(ws)

    entries = Activity.recent(ws, 20)
    assert Enum.any?(entries, &(&1.source == :jido_budgets and &1.summary =~ "crash_rate"))
  end

  test "stale leases reject new work" do
    ws = "ws-lease-#{id()}"
    JidoBudgets.acquire_lease(ws, "stale-attempt")
    put_limits(default_attempt_deadline_ms: 1, max_leaked_leases: 0)

    assert Eventually.await(
             fn -> JidoBudgets.snapshot().ledger.leaked_leases >= 1 end,
             timeout_ms: 1_000,
             interval_ms: 1,
             message: "lease did not become stale"
           )

    assert {:error, :lease_leak} = JidoPod.admit(%{workspace_id: ws, actions: []})
    assert JidoBudgets.snapshot().ledger.leaked_leases >= 1
  end

  test "resource pressure drains the queue before rejecting" do
    ws = "ws-pressure-#{id()}"
    gate = start_gate()
    Application.put_env(:casein, :jido_code_actions, gate_runner(gate))
    put_limits(max_running_per_workspace: 1, max_queued_per_workspace: 2)

    running = admit_blocked(ws, "run")
    queued = admit_blocked(ws, "q")
    assert_receive {:jido_action, "run", _}
    assert queued.state == :queued

    Application.put_env(:casein, :jido_budget_sampler, fn ->
      %{
        status: "constrained",
        reasons: ["available memory is below configured minimum"],
        cpu_ratio: 0.2,
        rss_bytes: 2_000_000_000,
        available?: true,
        healthy?: false
      }
    end)

    assert {:error, :rss_pressure} = JidoPod.admit(%{workspace_id: ws, actions: []})

    assert {:ok, %{state: :cancelled, reason: :rss_pressure}} =
             JidoPod.status(ws, queued.attempt_id)

    release(gate, "run")
    assert {:ok, %{state: state}} = JidoPod.await(ws, running.attempt_id)
    assert state in [:completed, :cancelled]
  end

  test "activity and snapshot never include prompts or secrets" do
    ws = "ws-redact-#{id()}"

    JidoBudgets.record(ws, :reject, :queue_full, %{queue_depth: 4, prompt: "SECRET", token: "abc"})

    snap = inspect(JidoBudgets.snapshot(ws))
    refute snap =~ "SECRET"
    refute snap =~ "abc"

    entries = Activity.recent(ws, 10)
    assert Enum.any?(entries, &(&1.source == :jido_budgets))
    refute Enum.any?(entries, &(inspect(&1) =~ "SECRET"))
  end

  test "benchmark covers idle/burst/slow/fail/cancel/contention and emits go/no-go" do
    report = JidoBudgets.benchmark(n: 3, timeout_ms: 3_000)

    assert report.revision
    assert is_map(report.configuration)
    assert report.provider_mode == :stub
    assert :idle in report.task_mix
    assert report.sample_size == 3
    assert report.scenarios.idle.workers == 0
    assert report.scenarios.burst.n == 3
    assert :completed in report.scenarios.burst.results
    assert report.scenarios.slow.elapsed_ms >= 0
    assert report.scenarios.fail.state == :provider_unavailable
    assert report.scenarios.cancel.cancelled == 1
    assert report.scenarios.contention.both_workspaces_ran
    assert report.comparison.opencode.requires_tmux_pane
    refute report.comparison.jido.requires_tmux_pane
    assert report.comparison.process_ratio < 1.0
    assert report.verdict.thresholds.go_process_ratio == 0.5
    assert is_boolean(report.verdict.go?)
    assert is_boolean(report.verdict.rollback?)
  end

  test "verdict rolls back when Jido is not cheaper or leases leak" do
    report = %{
      comparison: %{process_ratio: 1.2, rss_ratio: 0.1, error_rate: 0.0, leaked_leases: 1},
      scenarios: %{
        cancel: %{cancelled: 1, requested: 1},
        contention: %{both_workspaces_ran: true}
      }
    }

    verdict = Verdict.evaluate(report)
    assert verdict.rollback?
    assert verdict.rollback_trigger in [:process_ratio, :leaked_leases]
    refute verdict.go?
  end

  defp admit_blocked(ws, token) do
    {:ok, attempt} = JidoPod.admit(%{workspace_id: ws, actions: [block(token)]})
    attempt
  end

  defp block(token), do: %{name: "code_read", args: %{token: token}}

  defp start_gate do
    start_supervised!({Agent, fn -> %{} end}, id: {:jido_budget_gate, System.unique_integer()})
  end

  defp gate_runner(gate) do
    parent = self()

    fn _name, args, ctx ->
      token = Map.get(args, :token) || Map.get(args, "token")
      send(parent, {:jido_action, token, ctx.attempt_id})
      wait_for_release(gate, token)
    end
  end

  defp wait_for_release(gate, token) do
    Eventually.await(
      fn -> Agent.get(gate, &Map.get(&1, token)) && {:ok, %{token: token}} end,
      timeout_ms: 5_000,
      interval_ms: 10
    )
  end

  defp release(gate, token), do: Agent.update(gate, &Map.put(&1, token, true))

  defp put_limits(limits) do
    current = Application.get_env(:casein, :jido_pod, [])
    Application.put_env(:casein, :jido_pod, Keyword.merge(current, limits))
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)

  defp id, do: Integer.to_string(System.unique_integer([:positive]))
end
