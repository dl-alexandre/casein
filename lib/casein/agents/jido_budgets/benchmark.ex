defmodule Casein.Agents.JidoBudgets.Benchmark do
  @moduledoc """
  Repeatable OpenCode-vs-Jido resource benchmark.

  Measures the live Jido pod. OpenCode numbers are the documented cost model
  (one OS/TUI process + pane per worker) so the comparison stays honest when
  this suite cannot spawn a real OpenCode fleet.
  """

  alias Casein.Agents.JidoBudgets
  alias Casein.Agents.JidoBudgets.{Limits, Sampler, Verdict}
  alias Casein.Agents.JidoPod
  alias Casein.Agents.JidoPod.{Fleet, Metrics}
  alias Casein.Deployment.Version

  @scenarios [:idle, :burst, :slow, :fail, :cancel, :contention]

  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    n = Keyword.get(opts, :n, 4)
    timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)
    previous = snapshot_env()
    started = System.monotonic_time(:millisecond)

    Application.put_env(:casein, :jido_headless, true)
    Metrics.reset()
    Fleet.reset()
    JidoBudgets.reset()

    try do
      idle = scenario_idle()
      burst = scenario_burst(n, timeout_ms)
      slow = scenario_slow(timeout_ms)
      fail = scenario_fail(timeout_ms)
      cancel = scenario_cancel(timeout_ms)
      contention = scenario_contention(timeout_ms)

      scenarios = %{
        idle: idle,
        burst: burst,
        slow: slow,
        fail: fail,
        cancel: cancel,
        contention: contention
      }

      comparison = compare(n, burst, fail, cancel, contention)
      report = wrap(n, started, scenarios, comparison)
      Map.put(report, :verdict, Verdict.evaluate(report))
    after
      restore_env(previous)
    end
  end

  defp scenario_idle do
    host = Sampler.snapshot()

    %{
      name: :idle,
      process_count: host.process_count,
      memory_bytes: host.memory_bytes,
      rss_bytes: host.rss_bytes,
      cpu_ratio: host.cpu_ratio,
      workers: 0
    }
  end

  defp scenario_burst(n, timeout_ms) do
    ws = workspace("burst")
    Application.put_env(:casein, :jido_code_actions, &sync_ok/3)
    before = Sampler.snapshot()
    started = System.monotonic_time(:millisecond)

    results =
      1..n
      |> Enum.map(fn _ ->
        {:ok, attempt} = JidoPod.admit(%{workspace_id: ws, runtime: :jido, actions: []})
        attempt
      end)
      |> Enum.map(fn attempt ->
        case JidoPod.await(ws, attempt.attempt_id, timeout_ms) do
          {:ok, done} -> done.state
          {:error, reason} -> reason
        end
      end)

    elapsed = max(System.monotonic_time(:millisecond) - started, 1)
    after_host = Sampler.snapshot()
    _ = JidoPod.stop_pod(ws)

    %{
      name: :burst,
      n: n,
      elapsed_ms: elapsed,
      throughput_per_s: n * 1000 / elapsed,
      results: results,
      process_delta: after_host.process_count - before.process_count,
      memory_delta: after_host.memory_bytes - before.memory_bytes,
      rss_delta: delta(after_host.rss_bytes, before.rss_bytes),
      process_count: after_host.process_count,
      memory_bytes: after_host.memory_bytes
    }
  end

  defp scenario_slow(timeout_ms) do
    ws = workspace("slow")
    Application.put_env(:casein, :jido_code_actions, &slow_ok/3)
    started = System.monotonic_time(:millisecond)

    {:ok, attempt} =
      JidoPod.admit(%{
        workspace_id: ws,
        runtime: :jido,
        deadline_ms: timeout_ms,
        action_timeout_ms: timeout_ms,
        actions: [%{name: "code_read", args: %{}}]
      })

    result = JidoPod.await(ws, attempt.attempt_id, timeout_ms)
    elapsed = System.monotonic_time(:millisecond) - started
    state = result_state(result)
    _ = JidoPod.stop_pod(ws)

    %{name: :slow, elapsed_ms: elapsed, state: state}
  end

  defp scenario_fail(timeout_ms) do
    ws = workspace("fail")
    Application.put_env(:casein, :jido_code_actions, &provider_fail/3)

    {:ok, attempt} =
      JidoPod.admit(%{
        workspace_id: ws,
        runtime: :jido,
        actions: [%{name: "code_read", args: %{}}]
      })

    result = JidoPod.await(ws, attempt.attempt_id, timeout_ms)
    state = result_state(result)
    _ = JidoPod.stop_pod(ws)

    %{name: :fail, state: state}
  end

  defp scenario_cancel(timeout_ms) do
    ws = workspace("cancel")
    gate = start_gate()
    Application.put_env(:casein, :jido_code_actions, gate_runner(gate))

    {:ok, attempt} =
      JidoPod.admit(%{
        workspace_id: ws,
        runtime: :jido,
        actions: [%{name: "code_read", args: %{token: "hold"}}]
      })

    wait_until(fn ->
      match?({:ok, %{state: :running}}, JidoPod.status(ws, attempt.attempt_id))
    end)

    {:ok, _} = JidoPod.cancel(ws, attempt.attempt_id)
    result = JidoPod.await(ws, attempt.attempt_id, timeout_ms)
    state = result_state(result)
    _ = JidoPod.stop_pod(ws)
    stop_gate(gate)

    %{
      name: :cancel,
      requested: 1,
      cancelled: if(state == :cancelled, do: 1, else: 0),
      state: state
    }
  end

  defp scenario_contention(timeout_ms) do
    a = workspace("cont-a")
    b = workspace("cont-b")
    gate = start_gate()
    Application.put_env(:casein, :jido_code_actions, gate_runner(gate))

    previous = Application.get_env(:casein, :jido_pod, [])

    Application.put_env(
      :casein,
      :jido_pod,
      Keyword.merge(previous,
        max_running_per_workspace: 2,
        max_queued_per_workspace: 2,
        max_running_fleet: 2,
        max_share_per_workspace: 0.5
      )
    )

    {:ok, a1} = admit_hold(a, "a1")
    {:ok, a2} = admit_hold(a, "a2")
    {:ok, b1} = admit_hold(b, "b1")

    wait_until(fn ->
      match?({:ok, %{state: :running}}, JidoPod.status(a, a1.attempt_id))
    end)

    a2_state = status_state(a, a2.attempt_id)
    b1_state = status_state(b, b1.attempt_id)

    b1_state =
      if b1_state == :running do
        b1_state
      else
        release(gate, "a1")
        wait_until(fn -> match?({:ok, %{state: :running}}, JidoPod.status(b, b1.attempt_id)) end)
        status_state(b, b1.attempt_id)
      end

    both? = a2_state != :running and b1_state == :running

    release(gate, "a1")
    release(gate, "a2")
    release(gate, "b1")
    _ = JidoPod.await(a, a1.attempt_id, timeout_ms)
    _ = JidoPod.await(b, b1.attempt_id, timeout_ms)
    _ = JidoPod.stop_pod(a)
    _ = JidoPod.stop_pod(b)
    stop_gate(gate)
    Application.put_env(:casein, :jido_pod, previous)

    %{
      name: :contention,
      both_workspaces_ran: both?,
      busy_second: a2_state,
      other_first: b1_state
    }
  end

  defp compare(n, burst, fail, cancel, contention) do
    opencode_rss = n * Limits.get(:opencode_rss_per_worker_bytes)
    jido_rss = max(burst.rss_delta || burst.memory_delta, 0)
    jido_procs = max(burst.process_delta, 0)
    completed = Enum.count(burst.results, &(&1 == :completed))
    failed = Enum.count(burst.results, &(&1 in [:failed, :provider_unavailable, :timeout]))

    %{
      process_ratio: ratio(jido_procs, n),
      rss_ratio: ratio(jido_rss, opencode_rss),
      error_rate: ratio(failed, max(completed + failed, 1)),
      leaked_leases: JidoBudgets.snapshot().ledger.leaked_leases,
      cancel_ok?: cancel.cancelled == cancel.requested,
      fairness_ok?: contention.both_workspaces_ran,
      fail_state: fail.state,
      opencode: %{
        mode: :documented_baseline,
        workers: n,
        process_count: n,
        rss_bytes: opencode_rss,
        requires_tmux_pane: true,
        note: "legacy OpenCode: one OS/TUI process and tmux pane per worker"
      },
      jido: %{
        mode: :measured,
        workers: n,
        process_delta: jido_procs,
        rss_delta: jido_rss,
        memory_delta: burst.memory_delta,
        requires_tmux_pane: false,
        throughput_per_s: burst.throughput_per_s
      }
    }
  end

  defp wrap(n, started, scenarios, comparison) do
    %{
      revision: Version.version(),
      configuration: Limits.public(),
      provider_mode: :stub,
      task_mix: @scenarios,
      sample_size: n,
      elapsed_ms: System.monotonic_time(:millisecond) - started,
      scenarios: scenarios,
      comparison: comparison
    }
  end

  defp admit_hold(ws, token) do
    JidoPod.admit(%{
      workspace_id: ws,
      runtime: :jido,
      actions: [%{name: "code_read", args: %{token: token}}]
    })
  end

  defp status_state(ws, attempt_id) do
    case JidoPod.status(ws, attempt_id) do
      {:ok, %{state: state}} -> state
      _ -> :unknown
    end
  end

  defp result_state({:ok, %{state: state}}), do: state
  defp result_state({:error, reason}), do: reason
  defp result_state(_), do: :unknown

  defp sync_ok(_name, args, _ctx), do: {:ok, args}

  defp slow_ok(_name, args, _ctx) do
    Process.sleep(20)
    {:ok, args}
  end

  defp provider_fail(_name, _args, _ctx), do: {:error, :provider_unavailable}

  defp start_gate do
    {:ok, pid} = Agent.start_link(fn -> %{} end)
    pid
  end

  defp stop_gate(pid) do
    if Process.alive?(pid), do: Agent.stop(pid)
    :ok
  end

  defp gate_runner(gate) do
    fn _name, args, _ctx ->
      token = Map.get(args, :token) || Map.get(args, "token")
      wait_for_release(gate, token)
    end
  end

  defp wait_for_release(gate, token) do
    wait_until(fn -> Agent.get(gate, &Map.get(&1, token)) end)
    {:ok, %{token: token}}
  end

  defp release(gate, token), do: Agent.update(gate, &Map.put(&1, token, true))

  defp wait_until(fun), do: spin(fun, 200)

  defp spin(_fun, 0), do: false

  defp spin(fun, n) do
    if fun.(), do: true, else: Process.sleep(10) && spin(fun, n - 1)
  end

  defp workspace(label), do: "jido-bench-#{label}-#{System.unique_integer([:positive])}"

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den) when is_number(num) and is_number(den), do: num / den
  defp ratio(_, _), do: 0.0

  defp delta(nil, _), do: 0
  defp delta(_, nil), do: 0
  defp delta(after_v, before_v), do: after_v - before_v

  defp snapshot_env do
    %{
      flag: Application.get_env(:casein, :jido_headless),
      runner: Application.get_env(:casein, :jido_code_actions),
      pod: Application.get_env(:casein, :jido_pod)
    }
  end

  defp restore_env(previous) do
    restore(:jido_headless, previous.flag)
    restore(:jido_code_actions, previous.runner)
    restore(:jido_pod, previous.pod)
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
