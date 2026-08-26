defmodule Casein.Agents.JidoActionsTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.{Activity, JidoActions, JidoPod}
  alias Casein.Agents.JidoActions.Compatibility
  alias Casein.Runtimes
  alias Casein.Test.Eventually
  alias Casein.Workspace
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter

  @workspace_id "ws-jido-actions"

  setup do
    previous = %{
      flag: Application.get_env(:casein, :jido_headless),
      workspaces: Application.get_env(:casein, :jido_headless_workspaces),
      runner: Application.get_env(:casein, :jido_code_actions),
      code: Application.get_env(:casein, :jido_actions_code_invoke),
      state: Application.get_env(:casein, :workspace_state_adapter),
      runtimes: Application.get_env(:casein, :runtimes_adapter)
    }

    base = Path.join(System.tmp_dir!(), "jido-actions-#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")

    Application.put_env(:casein, :jido_headless, true)
    Application.put_env(:casein, :jido_headless_workspaces, %{})
    Application.put_env(:casein, :jido_code_actions, fn _name, args, _ctx -> {:ok, args} end)
    Application.put_env(:casein, :workspace_state_adapter, MemoryAdapter)
    Application.put_env(:casein, :runtimes_adapter, Casein.Runtimes.MemoryAdapter)

    MemoryAdapter.clear()
    Runtimes.clear()
    Activity.clear()
    init_repo!(repo)
    seed_workspace!(@workspace_id, "jido-actions", repo)

    on_exit(fn ->
      _ = JidoPod.stop_pod(@workspace_id)

      Registry.select(Casein.Agents.JidoPod.Registry, [
        {{{:pod, :"$1"}, :_, :_}, [], [:"$1"]}
      ])
      |> Enum.each(&JidoPod.stop_pod/1)

      MemoryAdapter.clear()
      Runtimes.clear()
      Activity.clear()
      File.rm_rf!(base)
      restore(:jido_headless, previous.flag)
      restore(:jido_headless_workspaces, previous.workspaces)
      restore(:jido_code_actions, previous.runner)
      restore(:jido_actions_code_invoke, previous.code)
      restore(:workspace_state_adapter, previous.state)
      restore(:runtimes_adapter, previous.runtimes)
    end)

    %{repo: repo, ctx: trusted(repo)}
  end

  test "catalog lists one action per capability and excludes keystroke tools" do
    names = JidoActions.names()

    assert "code_read" in names
    assert "request_human_input" in names
    assert "git_status" in names
    refute "terminal_send_keys" in names
    refute "terminal_capture" in names
    assert Enum.all?(JidoActions.catalog(), &(&1.name in names))
  end

  test "flag off is a distinct deny so OpenCode stays on MCP" do
    Application.put_env(:casein, :jido_headless, false)

    assert Compatibility.path(@workspace_id) == :legacy_opencode

    assert {:error, %{result: :denied, error: :legacy_opencode}} =
             JidoActions.invoke("code_read", %{path: "README.md"}, %{
               workspace_id: @workspace_id
             })
  end

  test "trusted context wins and conflicting args are denied", %{repo: repo, ctx: ctx} do
    assert {:error, %{result: :denied, reason: :workspace_scope_mismatch}} =
             JidoActions.invoke(
               "code_read",
               %{path: "README.md", workspace_id: "ws-other"},
               ctx
             )

    other = Path.join(Path.dirname(repo), "other")
    File.mkdir_p!(other)

    assert {:error, %{result: :denied, reason: :workspace_scope_mismatch}} =
             JidoActions.invoke(
               "code_read",
               %{path: "README.md", worktree_path: other},
               ctx
             )
  end

  test "missing trusted workspace is invalid" do
    assert {:error, %{result: :invalid}} =
             JidoActions.invoke("code_read", %{path: "README.md"}, %{})
  end

  test "read search patch verify flow uses CodeTools and stubs git_diff", %{repo: repo, ctx: ctx} do
    File.write!(Path.join(repo, "lib/hello.ex"), "a\nb\nc\nd\n")

    assert {:ok, read} =
             JidoActions.invoke(
               "code_read",
               %{path: "lib/hello.ex", start_line: 2, end_line: 3},
               ctx
             )

    assert read.result == :ok
    assert read.content == "b\nc"
    assert read.workspace_id == @workspace_id
    assert read.correlation_id == "attempt-jido-actions"

    File.write!(Path.join(repo, "lib/a.ex"), "needle one\n")

    assert {:ok, search} = JidoActions.invoke("code_search", %{query: "needle"}, ctx)
    assert search.result == :ok
    assert search.match_count >= 1

    File.write!(Path.join(repo, "note.txt"), "hello\n")
    git!(repo, ["add", "note.txt"])
    git!(repo, ["commit", "-m", "add note"])
    File.write!(Path.join(repo, "note.txt"), "hello world\n")
    patch = git_diff!(repo, "note.txt")
    File.write!(Path.join(repo, "note.txt"), "hello\n")

    assert {:ok, applied} =
             JidoActions.invoke(
               "code_apply_patch",
               %{patch: patch, idempotency_key: "flow-1"},
               ctx
             )

    assert applied.result == :ok
    assert applied.applied

    verify =
      case JidoActions.invoke(
             "code_exec",
             %{command_id: "format", timeout_ms: 1, max_output_bytes: 32},
             ctx
           ) do
        {:ok, payload} -> payload
        {:error, %{result: :timeout} = payload} -> payload
      end

    assert verify.command_id == "format"
    assert verify.result in [:ok, :timeout]

    assert {:error, %{result: :not_yet_supported, error: :not_yet_supported}} =
             JidoActions.invoke("git_diff", %{}, ctx)
  end

  test "denied path and denied capability are stable denied results", %{ctx: ctx} do
    assert {:error, %{result: :denied, error: reason}} =
             JidoActions.invoke("code_read", %{path: "/etc/passwd"}, ctx)

    assert reason in [:absolute_path, :outside_root, :denied]

    assert {:error, %{result: :denied, error: :not_allowed}} =
             JidoActions.invoke("code_exec", %{command_id: "rm -rf /"}, ctx)
  end

  test "human-input request is blocked_on_human and records activity", %{ctx: ctx} do
    assert {:error,
            %{
              result: :blocked_on_human,
              error: :awaiting_human,
              awaiting_human: true
            }} =
             JidoActions.invoke(
               "request_human_input",
               %{
                 request_id: "need-human-01",
                 kind: "clarification",
                 prompt: "Which module?"
               },
               ctx
             )

    entries = Activity.recent(@workspace_id, 20)
    assert Enum.any?(entries, &(&1.source == :jido_actions and &1.tool == "request_human_input"))
    refute Enum.any?(entries, &match?(%{metadata: %{pane_id: pane}} when is_binary(pane), &1))
  end

  test "timeout, cancel, stale attempt, and provider failure are distinct", %{
    repo: repo,
    ctx: ctx
  } do
    Application.put_env(:casein, :jido_actions_code_invoke, fn _name, _args, _ctx ->
      {:ok, %{timed_out: true, cancelled: true, status: "timeout"}}
    end)

    assert {:error, %{result: :timeout, error: :timeout, retryable: true}} =
             JidoActions.invoke("code_read", %{path: "README.md"}, ctx)

    Application.put_env(:casein, :jido_actions_code_invoke, fn _name, _args, _ctx ->
      {:error, :provider_unavailable}
    end)

    assert {:error, %{result: :provider_failure, error: :provider_unavailable, retryable: true}} =
             JidoActions.invoke("code_read", %{path: "README.md"}, ctx)

    Application.put_env(:casein, :jido_actions_code_invoke, fn _name, _args, _ctx ->
      {:ok, %{status: "failed", exit_code: 1, output: "verification failed"}}
    end)

    assert {:error, %{result: :invalid, error: :verification_failed, status: "failed"}} =
             JidoActions.invoke("code_exec", %{command_id: "test"}, ctx)

    {:ok, done} = JidoPod.admit(%{workspace_id: @workspace_id, runtime: :jido, actions: []})
    assert {:ok, %{state: :completed}} = JidoPod.await(@workspace_id, done.attempt_id)

    assert {:error, %{result: :stale_attempt, error: :stale_attempt}} =
             JidoActions.invoke("code_read", %{path: "README.md"}, %{
               ctx
               | attempt_id: done.attempt_id
             })

    gate = start_supervised!({Agent, fn -> %{} end})

    Application.put_env(:casein, :jido_code_actions, fn _name, args, _ctx ->
      token = Map.get(args, :token) || Map.get(args, "token")

      Eventually.await(
        fn -> Agent.get(gate, &Map.get(&1, token)) && {:ok, %{token: token}} end,
        timeout_ms: 5_000,
        interval_ms: 10
      )
    end)

    {:ok, live} =
      JidoPod.admit(%{
        workspace_id: @workspace_id,
        runtime: :jido,
        actions: [%{name: "code_read", args: %{token: "hold"}}]
      })

    assert {:ok, _} = JidoPod.cancel(@workspace_id, live.attempt_id)

    assert {:ok, %{state: :cancelled}} =
             Eventually.await(
               fn ->
                 case JidoPod.status(@workspace_id, live.attempt_id) do
                   {:ok, %{state: :cancelled} = attempt} -> {:ok, attempt}
                   _ -> false
                 end
               end,
               timeout_ms: 2_000,
               message: "attempt did not reach cancelled"
             )

    Agent.update(gate, &Map.put(&1, "hold", true))

    assert {:error, %{result: :cancelled, error: :cancelled}} =
             JidoActions.invoke("code_read", %{path: "README.md"}, %{
               workspace_id: @workspace_id,
               attempt_id: live.attempt_id,
               worktree_path: repo,
               actor: "ws:#{@workspace_id}"
             })
  end

  test "keystroke and scrape tools are denied and never reach a shell", %{ctx: ctx} do
    assert {:error, %{result: :denied, error: :not_allowed}} =
             JidoActions.invoke("terminal_send_keys", %{keys: "C-c"}, ctx)

    assert {:error, %{result: :denied, error: :not_allowed}} =
             JidoActions.invoke("terminal_capture", %{lines: 20}, ctx)
  end

  test "compatibility adapter uses the same catalog when the flag is on", %{ctx: ctx} do
    assert Compatibility.path(@workspace_id) == :jido_actions

    assert {:error, %{result: :not_yet_supported}} =
             Compatibility.invoke("task_wait", %{}, ctx)
  end

  test "progress and evidence handoff are attributable without a pane", %{ctx: ctx} do
    assert {:ok, %{result: :ok, recorded: true}} =
             JidoActions.invoke("report_progress", %{summary: "patched note"}, ctx)

    assert {:ok, %{result: :ok}} =
             JidoActions.invoke(
               "handoff_evidence",
               %{
                 paths: ["note.txt"],
                 verification_ref: "format",
                 repository: "MILCGroup/OneBackend-v3",
                 pull_request: 19_418,
                 head_sha: "0123456789abcdef0123456789abcdef01234567",
                 review_thread_ids: ["thread-1"],
                 handoff_target: "dash",
                 review_resolution: "blind_listed_threads",
                 merge_policy: "resolve_listed_threads_at_head_sha"
               },
               ctx
             )

    tools = Activity.recent(@workspace_id, 20) |> Enum.map(& &1.tool)
    assert "report_progress" in tools
    assert "handoff_evidence" in tools
  end

  defp trusted(repo) do
    %{
      workspace_id: @workspace_id,
      task_id: "task-jido-actions",
      attempt_id: "attempt-jido-actions",
      worktree_path: repo,
      actor: "ws:#{@workspace_id}",
      correlation_id: "attempt-jido-actions"
    }
  end

  defp seed_workspace!(id, name, repo) do
    {:ok, _record} =
      State.sync(%Workspace{
        id: id,
        name: name,
        path: repo,
        status: :running,
        metadata: %{"id" => id, "name" => name}
      })
  end

  defp init_repo!(repo) do
    File.mkdir_p!(Path.join(repo, "lib"))
    git!(repo, ["init"])
    git!(repo, ["config", "user.name", "Casein Test"])
    git!(repo, ["config", "user.email", "casein-test@localhost"])
    File.write!(Path.join(repo, "README.md"), "# Jido actions\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "Initial commit"])
  end

  defp git_diff!(cwd, path) do
    case System.cmd("git", ["-C", cwd, "diff", "--", path], stderr_to_stdout: true) do
      {output, code} when code in [0, 1] and output != "" -> output
      {output, code} -> flunk("git diff failed with #{code}: #{output}")
    end
  end

  defp git!(cwd, args) do
    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}: #{output}")
    end
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
