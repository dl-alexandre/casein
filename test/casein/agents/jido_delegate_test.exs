defmodule Casein.Agents.JidoDelegateTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.{JidoDelegate, JidoPod, TerminalTools}
  alias Casein.Agents.JidoPod.{Fleet, Metrics}

  setup do
    previous = %{
      flag: Application.get_env(:casein, :jido_headless),
      workspaces: Application.get_env(:casein, :jido_headless_workspaces),
      runner: Application.get_env(:casein, :jido_code_actions)
    }

    Application.put_env(:casein, :jido_headless, false)
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
      restore(:jido_code_actions, previous.runner)
      Metrics.reset()
      Fleet.reset()
      Casein.Agents.JidoBudgets.reset()
    end)

    :ok
  end

  test "per-workspace flag selects Jido; explicit opencode stays on worker_launch" do
    ws = "ws-delegate-#{id()}"
    Application.put_env(:casein, :jido_headless_workspaces, %{ws => true})

    assert {:ok, %{runtime: :jido, fallback?: false, next_tool: "jido_admit"}} =
             JidoDelegate.select(ws, dry_run: true)

    other = "ws-delegate-off-#{id()}"

    assert {:ok,
            %{
              runtime: :opencode,
              fallback?: true,
              next_tool: "worker_launch",
              reason: :legacy_opencode
            }} =
             JidoDelegate.select(other)

    assert {:ok, %{runtime: :opencode, fallback?: true, reason: :explicit_opencode}} =
             JidoDelegate.admit(%{"workspace_id" => ws, "runtime" => "opencode"})
  end

  test "admit runs typed CodeTools and status/cancel stay headless" do
    ws = "ws-delegate-run-#{id()}"
    Application.put_env(:casein, :jido_headless_workspaces, %{ws => true})

    assert {:ok, admitted} =
             JidoDelegate.admit(%{
               workspace_id: ws,
               worktree_path: "/tmp/jido-demo",
               actions: [
                 %{
                   "name" => "code_read",
                   "args" => %{"path" => "README.md", "workspace_id" => "evil"}
                 }
               ]
             })

    assert admitted.runtime == :jido
    refute admitted.fallback?
    assert admitted.headless
    refute Map.has_key?(admitted, :pane_id)
    assert admitted.next_tool == "jido_status"

    assert {:ok, %{state: :completed, headless: true} = finished} =
             JidoPod.await(ws, admitted.attempt_id)

    refute Map.has_key?(finished, :pane_id)

    assert {:ok, status} =
             JidoDelegate.status(%{workspace_id: ws, attempt_id: admitted.attempt_id})

    assert status.state == :completed
    assert status.headless
    refute Map.has_key?(status, :pane_id)

    blocked = admit_blocked(ws)

    assert {:ok, cancelled} =
             JidoDelegate.cancel(%{workspace_id: ws, attempt_id: blocked.attempt_id})

    assert cancelled.state in [:cancelled, :running]
    assert {:ok, %{state: :cancelled}} = await_cancelled(ws, blocked.attempt_id)
  end

  test "terminal/tmux actions are refused and never reach the pod" do
    ws = "ws-delegate-deny-#{id()}"
    Application.put_env(:casein, :jido_headless_workspaces, %{ws => true})

    assert {:error, %{error: :not_allowed, action: "terminal_send_command"}} =
             JidoDelegate.admit(%{
               workspace_id: ws,
               actions: [%{name: "terminal_send_command", args: %{command: "rm -rf /"}}]
             })

    assert {:error, %{error: :not_yet_supported, action: "git_status"}} =
             JidoDelegate.admit(%{
               workspace_id: ws,
               actions: [%{name: "git_status"}]
             })

    assert JidoPod.list(ws) == []
  end

  test "MCP tools register and fail closed without required args" do
    names = TerminalTools.definitions() |> Enum.map(& &1.name)
    assert "jido_admit" in names
    assert "jido_status" in names
    assert "jido_cancel" in names

    admit = Enum.find(TerminalTools.definitions(), &(&1.name == "jido_admit"))
    assert admit.parameters.required == ["workspace_id"]
    assert admit.parameters.properties.runtime.enum == ["jido", "opencode"]

    assert admit.parameters.properties.actions.items.properties.name.enum ==
             ["code_read", "code_search", "code_apply_patch", "code_exec"]

    assert admit.metadata.mutation?
    refute Enum.find(TerminalTools.definitions(), &(&1.name == "jido_status")).metadata.mutation?

    assert {:error, {:missing_argument, "workspace_id"}} =
             TerminalTools.invoke("jido_admit", %{"actions" => []})

    assert {:error, {:missing_argument, "attempt_id"}} =
             TerminalTools.invoke("jido_status", %{"workspace_id" => "ws-1"})
  end

  test "disabled workspace falls back to worker_launch without starting a pod" do
    ws = "ws-delegate-fallback-#{id()}"

    assert {:ok, %{fallback?: true, next_tool: "worker_launch", runtime: :opencode}} =
             TerminalTools.invoke("jido_admit", %{
               "workspace_id" => ws,
               "actions" => [%{"name" => "code_read", "args" => %{"path" => "README.md"}}]
             })

    assert JidoPod.list(ws) == []
  end

  test "jido_admit threads trusted MCP principal and strips actor fields from action args" do
    ws = "ws-delegate-principal-#{id()}"
    Application.put_env(:casein, :jido_headless_workspaces, %{ws => true})
    parent = self()

    Application.put_env(:casein, :jido_code_actions, fn name, args, ctx ->
      send(parent, {:tool, name, args, ctx})
      {:ok, %{name: name}}
    end)

    assert {:ok, admitted} =
             TerminalTools.invoke(
               "jido_admit",
               %{
                 "workspace_id" => ws,
                 "worktree_path" => "/tmp/assigned",
                 "principal" => "spoofed-param",
                 "actor_id" => "spoofed-param",
                 "actions" => [
                   %{
                     "name" => "code_apply_patch",
                     "args" => %{"patch" => "--- a\n+++ b\n", "actor_id" => "spoofed"}
                   }
                 ]
               },
               %{actor: "dalexandre"}
             )

    assert admitted.runtime == :jido
    assert {:ok, %{state: :completed}} = JidoPod.await(ws, admitted.attempt_id)
    assert_receive {:tool, "code_apply_patch", args, ctx}
    refute Map.has_key?(args, :actor_id)
    refute Map.has_key?(args, "actor_id")
    refute Map.has_key?(args, :principal)
    assert ctx.actor == "dalexandre"
    assert ctx.principal == "dalexandre"
  end

  defp admit_blocked(ws) do
    gate = start_supervised!({Agent, fn -> %{} end}, id: {:jido_delegate_gate, id()})
    parent = self()

    Application.put_env(:casein, :jido_code_actions, fn _name, args, ctx ->
      send(parent, {:jido_action, ctx.attempt_id})
      wait_for_release(gate, ctx.attempt_id)
      {:ok, args}
    end)

    {:ok, admitted} =
      JidoDelegate.admit(%{
        workspace_id: ws,
        actions: [%{name: "code_read", args: %{path: "README.md"}}]
      })

    assert_receive {:jido_action, _}
    Map.put(admitted, :gate, gate)
  end

  defp wait_for_release(gate, token) do
    Casein.Test.Eventually.await(
      fn -> Agent.get(gate, &Map.get(&1, token)) && {:ok, :released} end,
      timeout_ms: 5_000,
      interval_ms: 10
    )
  end

  defp await_cancelled(ws, attempt_id) do
    Casein.Test.Eventually.await(
      fn ->
        case JidoPod.status(ws, attempt_id) do
          {:ok, %{state: :cancelled} = attempt} -> {:ok, attempt}
          _ -> false
        end
      end,
      timeout_ms: 2_000,
      message: "attempt #{attempt_id} did not cancel"
    )
  end

  defp sync_ok(_name, args, _ctx), do: {:ok, args}

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)

  defp id, do: Integer.to_string(System.unique_integer([:positive]))
end
