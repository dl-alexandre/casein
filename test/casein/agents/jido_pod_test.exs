defmodule Casein.Agents.JidoPodTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.Activity
  alias Casein.Agents.JidoPod
  alias Casein.Agents.JidoPod.{Attempt, Fleet, Metrics}
  alias Casein.Test.Eventually

  setup do
    previous = %{
      flag: Application.get_env(:casein, :jido_headless),
      workspaces: Application.get_env(:casein, :jido_headless_workspaces),
      pod: Application.get_env(:casein, :jido_pod),
      runner: Application.get_env(:casein, :jido_code_actions)
    }

    Application.put_env(:casein, :jido_headless, true)
    Application.put_env(:casein, :jido_headless_workspaces, %{})
    Application.put_env(:casein, :jido_code_actions, &sync_ok/3)
    Metrics.reset()
    Fleet.reset()
    Casein.Agents.JidoBudgets.reset()

    on_exit(fn ->
      Registry.select(Casein.Agents.JidoPod.Registry, [
        {{{:pod, :"$1"}, :_, :_}, [], [:"$1"]}
      ])
      |> Enum.each(&JidoPod.stop_pod/1)

      restore(:jido_headless, previous.flag)
      restore(:jido_headless_workspaces, previous.workspaces)
      restore(:jido_pod, previous.pod)
      restore(:jido_code_actions, previous.runner)
      Metrics.reset()
      Fleet.reset()
      Casein.Agents.JidoBudgets.reset()
    end)

    {:ok, track: fn ws -> ws end}
  end

  test "flag off selects legacy OpenCode and does not start a pod", %{track: track} do
    Application.put_env(:casein, :jido_headless, false)
    ws = track.("ws-flag-#{id()}")

    assert JidoPod.select_runtime(ws) == :opencode
    assert {:error, :legacy_opencode} = JidoPod.admit(%{workspace_id: ws, actions: []})
    assert JidoPod.list(ws) == []
  end

  test "per-workspace override enables Jido while global flag is off", %{track: track} do
    Application.put_env(:casein, :jido_headless, false)
    ws = track.("ws-override-#{id()}")
    Application.put_env(:casein, :jido_headless_workspaces, %{ws => true})

    assert JidoPod.select_runtime(ws) == :jido
    assert {:ok, attempt} = JidoPod.admit(%{workspace_id: ws, actions: []})
    assert {:ok, %{state: :completed, headless: true}} = JidoPod.await(ws, attempt.attempt_id)
    refute Map.has_key?(attempt, :pane_id)
  end

  test "explicit runtime: :opencode stays on the legacy path when the flag is on", %{track: track} do
    ws = track.("ws-legacy-#{id()}")
    assert {:error, :legacy_opencode} = JidoPod.admit(%{workspace_id: ws, runtime: :opencode})
  end

  test "two concurrent attempts run and the next is queued then rejected", %{track: track} do
    ws = track.("ws-cap-#{id()}")
    gate = start_gate()
    Application.put_env(:casein, :jido_code_actions, gate_runner(gate))
    put_limits(max_running_per_workspace: 2, max_queued_per_workspace: 1, max_running_fleet: 8)

    a = admit_blocked(ws, "a")
    b = admit_blocked(ws, "b")
    assert_receive {:jido_action, "a", _}
    assert_receive {:jido_action, "b", _}
    assert {:ok, %{state: :running}} = JidoPod.status(ws, a.attempt_id)
    assert {:ok, %{state: :running}} = JidoPod.status(ws, b.attempt_id)

    c = admit_blocked(ws, "c")
    assert c.state == :queued

    assert {:error, :backpressure} = JidoPod.admit(%{workspace_id: ws, actions: [block("d")]})

    release(gate, "a")
    release(gate, "b")
    assert {:ok, %{state: :completed}} = JidoPod.await(ws, a.attempt_id)
    assert {:ok, %{state: :completed}} = JidoPod.await(ws, b.attempt_id)
    assert_receive {:jido_action, "c", _}
    release(gate, "c")
    assert {:ok, %{state: :completed}} = JidoPod.await(ws, c.attempt_id)
  end

  test "cancelling one attempt does not kill another or wedge the pod", %{track: track} do
    ws = track.("ws-cancel-#{id()}")
    gate = start_gate()
    Application.put_env(:casein, :jido_code_actions, gate_runner(gate))

    a = admit_blocked(ws, "keep")
    b = admit_blocked(ws, "drop")
    assert_receive {:jido_action, "keep", _}
    assert_receive {:jido_action, "drop", _}

    assert {:ok, _} = JidoPod.cancel(ws, b.attempt_id)
    assert {:ok, %{state: :cancelled}} = await_state(ws, b.attempt_id, :cancelled)

    release(gate, "keep")
    assert {:ok, %{state: :completed}} = JidoPod.await(ws, a.attempt_id)
    assert {:ok, queued} = JidoPod.admit(%{workspace_id: ws, actions: []})
    assert {:ok, %{state: :completed}} = JidoPod.await(ws, queued.attempt_id)
  end

  test "a crashed worker is recorded, releases its lease, and does not replay completed mutations",
       %{track: track} do
    ws = track.("ws-crash-#{id()}")
    parent = self()

    Application.put_env(:casein, :jido_code_actions, fn name, args, ctx ->
      send(parent, {:invoked, name, Map.get(args, :step), ctx.attempt_id})

      case Map.get(args, :step) do
        "one" -> {:ok, %{step: "one"}}
        "two" -> exit(:boom)
      end
    end)

    {:ok, attempt} =
      JidoPod.admit(%{
        workspace_id: ws,
        max_retries: 1,
        actions: [
          %{name: "code_read", args: %{step: "one"}, mutation_token: "mut-1"},
          %{name: "code_apply_patch", args: %{step: "two"}, mutation_token: "mut-2"}
        ]
      })

    assert_receive {:invoked, "code_read", "one", _}
    assert_receive {:invoked, "code_apply_patch", "two", _}
    assert_receive {:invoked, "code_apply_patch", "two", _}
    refute_received {:invoked, "code_read", "one", _}

    assert {:ok, %{state: :failed, next_index: 1}} = JidoPod.await(ws, attempt.attempt_id)

    {:ok, follow} = JidoPod.admit(%{workspace_id: ws, actions: []})
    assert {:ok, %{state: :completed}} = JidoPod.await(ws, follow.attempt_id)
  end

  test "workspace isolation: one busy workspace does not starve another", %{track: track} do
    a = track.("ws-iso-a-#{id()}")
    b = track.("ws-iso-b-#{id()}")
    gate = start_gate()
    Application.put_env(:casein, :jido_code_actions, gate_runner(gate))
    put_limits(max_running_per_workspace: 2, max_queued_per_workspace: 2, max_running_fleet: 8)

    _a1 = admit_blocked(a, "a1")
    _a2 = admit_blocked(a, "a2")
    assert_receive {:jido_action, "a1", _}
    assert_receive {:jido_action, "a2", _}

    b1 = admit_blocked(b, "b1")
    assert_receive {:jido_action, "b1", _}
    assert {:ok, %{state: :running}} = JidoPod.status(b, b1.attempt_id)

    release(gate, "a1")
    release(gate, "a2")
    release(gate, "b1")
    assert {:ok, %{state: :completed}} = JidoPod.await(b, b1.attempt_id)
  end

  test "fleet fairness starts the waiting workspace with fewer running workers", %{track: track} do
    a = track.("ws-fair-a-#{id()}")
    b = track.("ws-fair-b-#{id()}")
    gate = start_gate()
    Application.put_env(:casein, :jido_code_actions, gate_runner(gate))

    put_limits(
      max_running_per_workspace: 2,
      max_queued_per_workspace: 4,
      max_running_fleet: 2,
      max_share_per_workspace: 1.0
    )

    _a1 = admit_blocked(a, "a1")
    _a2 = admit_blocked(a, "a2")
    assert_receive {:jido_action, "a1", _}
    assert_receive {:jido_action, "a2", _}

    b1 = admit_blocked(b, "b1")
    assert b1.state == :queued
    a3 = admit_blocked(a, "a3")
    assert a3.state == :queued

    release(gate, "a1")
    assert_receive {:jido_action, "b1", _}
    assert {:ok, %{state: :running}} = JidoPod.status(b, b1.attempt_id)
    assert {:ok, %{state: :queued}} = JidoPod.status(a, a3.attempt_id)

    release(gate, "a2")
    release(gate, "b1")
    release(gate, "a3")
  end

  test "workers call typed code actions and reject follow-up tools", %{track: track} do
    ws = track.("ws-tools-#{id()}")
    parent = self()

    Application.put_env(:casein, :jido_code_actions, fn name, args, ctx ->
      send(parent, {:tool, name, args, ctx})
      {:ok, %{name: name}}
    end)

    {:ok, attempt} =
      JidoPod.admit(%{
        workspace_id: ws,
        worktree_path: "/tmp/assigned",
        actions: [%{name: "code_search", args: %{query: "Pod"}}]
      })

    assert {:ok, %{state: :completed}} = JidoPod.await(ws, attempt.attempt_id)
    assert_receive {:tool, "code_search", args, ctx}
    assert args[:query] == "Pod" or args["query"] == "Pod"
    assert ctx.workspace_id == ws
    assert ctx.worktree_path == "/tmp/assigned"

    {:ok, denied} =
      JidoPod.admit(%{workspace_id: ws, actions: [%{name: "git_status", args: %{}}]})

    assert {:ok, %{state: :failed}} = JidoPod.await(ws, denied.attempt_id)
  end

  test "awaiting_human, timeout, and provider_unavailable are distinct states", %{track: track} do
    ws = track.("ws-states-#{id()}")

    Application.put_env(:casein, :jido_code_actions, fn _name, args, _ctx ->
      case Map.get(args, :mode) do
        "human" -> {:ok, %{status: :awaiting_human}}
        "provider" -> {:error, :provider_unavailable}
      end
    end)

    {:ok, human} =
      JidoPod.admit(%{workspace_id: ws, actions: [%{name: "code_read", args: %{mode: "human"}}]})

    assert {:ok, %{state: :awaiting_human}} = await_state(ws, human.attempt_id, :awaiting_human)

    Application.put_env(:casein, :jido_code_actions, fn _name, _args, _ctx ->
      {:ok, %{resumed: true}}
    end)

    assert {:ok, resumed} = JidoPod.resume(ws, human.attempt_id)
    assert {:ok, %{state: :completed}} = JidoPod.await(ws, resumed.attempt_id)

    Application.put_env(:casein, :jido_code_actions, fn _name, args, _ctx ->
      case Map.get(args, :mode) do
        "provider" -> {:error, :provider_unavailable}
      end
    end)

    {:ok, provider} =
      JidoPod.admit(%{
        workspace_id: ws,
        actions: [%{name: "code_read", args: %{mode: "provider"}}]
      })

    assert {:ok, %{state: :provider_unavailable}} = JidoPod.await(ws, provider.attempt_id)

    Application.put_env(:casein, :jido_code_actions, fn _name, _args, _ctx ->
      receive do
        :never -> :ok
      end
    end)

    {:ok, timed} =
      JidoPod.admit(%{
        workspace_id: ws,
        deadline_ms: 30,
        actions: [%{name: "code_read", args: %{}}]
      })

    assert {:ok, %{state: :timed_out}} = JidoPod.await(ws, timed.attempt_id, 1_000)
  end

  test "activity is recorded without inventing a pane and drain cancels the queue", %{
    track: track
  } do
    ws = track.("ws-drain-#{id()}")
    gate = start_gate()
    Application.put_env(:casein, :jido_code_actions, gate_runner(gate))
    put_limits(max_running_per_workspace: 1, max_queued_per_workspace: 2, max_running_fleet: 8)

    running = admit_blocked(ws, "run")
    queued = admit_blocked(ws, "q")
    assert_receive {:jido_action, "run", _}
    assert queued.state == :queued

    assert {:ok, cancelled} = JidoPod.drain(ws)
    assert Enum.any?(cancelled, &(&1.attempt_id == queued.attempt_id))
    assert {:ok, %{state: :cancelled}} = JidoPod.status(ws, queued.attempt_id)

    entries = Activity.recent(ws, 20)
    assert Enum.any?(entries, &(&1.source == :jido_pod and &1.tool == "jido_pod"))
    refute Enum.any?(entries, &match?(%{metadata: %{pane_id: pane}} when is_binary(pane), &1))

    release(gate, "run")
    assert {:ok, %{state: state}} = JidoPod.await(ws, running.attempt_id)
    assert state in [:completed, :cancelled]
  end

  test "benchmark records process count, memory, latency, and the OpenCode baseline", %{
    track: track
  } do
    ws = track.("ws-bench-#{id()}")
    snap = JidoPod.benchmark(n: 3, workspace_id: ws, timeout_ms: 2_000)

    assert snap.n == 3
    assert snap.elapsed_ms >= 0
    assert snap.throughput_per_s > 0
    assert snap.process_count_after >= 1
    assert snap.memory_bytes_after > 0
    assert snap.opencode_baseline.requires_tmux_pane
    assert snap.opencode_baseline.processes_per_worker == 1
    assert :completed in snap.results
  end

  test "attempt states cover the required lifecycle vocabulary" do
    expected =
      ~w(admitted queued running awaiting_human retrying completed failed cancelled timed_out provider_unavailable)a

    assert Attempt.states() == expected
  end

  defp admit_blocked(ws, token) do
    {:ok, attempt} = JidoPod.admit(%{workspace_id: ws, actions: [block(token)]})
    attempt
  end

  defp block(token), do: %{name: "code_read", args: %{token: token}}

  defp start_gate do
    start_supervised!({Agent, fn -> %{} end}, id: {:jido_gate, System.unique_integer()})
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

  defp await_state(ws, attempt_id, state) do
    Eventually.await(
      fn ->
        case JidoPod.status(ws, attempt_id) do
          {:ok, %{state: ^state} = attempt} -> {:ok, attempt}
          _ -> false
        end
      end,
      timeout_ms: 2_000,
      message: "attempt #{attempt_id} did not reach #{state}"
    )
  end

  defp put_limits(limits) do
    current = Application.get_env(:casein, :jido_pod, [])
    Application.put_env(:casein, :jido_pod, Keyword.merge(current, limits))
  end

  defp sync_ok(_name, args, _ctx), do: {:ok, args}

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)

  defp id, do: Integer.to_string(System.unique_integer([:positive]))
end
