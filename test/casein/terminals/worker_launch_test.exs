defmodule Casein.Terminals.WorkerLaunchTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.WorkerLaunch

  @ws "ws-launch-1"
  @session "casein_ws-launch-1_main"

  describe "launch/1 validation" do
    test "fails closed without required fields" do
      assert {:error, %{error: :missing_argument, argument: "workspace_id"}} =
               WorkerLaunch.launch([])

      assert {:error, %{error: :missing_argument, argument: "session"}} =
               WorkerLaunch.launch(workspace_id: @ws)

      assert {:error, %{error: :missing_argument, argument: "runtime"}} =
               WorkerLaunch.launch(workspace_id: @ws, session: @session)

      assert {:error, %{error: :missing_argument, argument: "task_slug"}} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "opencode"
               )
    end

    test "rejects unsupported runtime" do
      assert {:error, %{error: :unsupported_runtime, runtime: "cursor"}} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "cursor",
                 task_slug: "demo"
               )
    end

    test "sanitizes task_slug" do
      runner = fn runtime, slug, session, opts ->
        send(self(), {:ran, runtime, slug, session, opts[:dry_run]})
        {:ok, %{dry_run: true, window_name: "worker-#{slug}"}}
      end

      assert {:ok, %{task_slug: "hello-world", dry_run: true}} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "opencode",
                 task_slug: "hello world!!",
                 dry_run: true,
                 runner: runner
               )

      assert_received {:ran, "opencode", "hello-world", @session, true}
    end
  end

  describe "launch/1 receipt" do
    test "live spawn returns visible receipt with handle optional" do
      runner = fn _rt, slug, _sess, _opts ->
        {:ok, %{pane_id: "%42", window_name: "worker-#{slug}"}}
      end

      observe = fn _sess, pane ->
        assert pane == "%42"

        %{
          window_id: "@9",
          window_name: "worker-demo",
          worktree_path: "/tmp/casein-agent-worktrees/wt-demo",
          branch: "agent/opencode/demo-stamp"
        }
      end

      assert {:ok, receipt} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "opencode",
                 task_slug: "demo",
                 label: "worker: #384",
                 runner: runner,
                 observe: observe,
                 attach_handle: false
               )

      assert receipt.ok == true
      assert receipt.visible? == true
      assert receipt.hidden_subagent? == false
      assert receipt.pane_id == "%42"
      assert receipt.window_name == "worker-demo"
      assert receipt.window_id == "@9"
      assert receipt.worktree_path == "/tmp/casein-agent-worktrees/wt-demo"
      assert receipt.branch == "agent/opencode/demo-stamp"
      assert receipt.label == "worker: #384"
      assert receipt.runtime == "opencode"
      assert receipt.note =~ "M4-lite"
      refute Map.has_key?(receipt, :handle_id)
    end

    test "spawn failure is structured, not a raised exception" do
      runner = fn _, _, _, _ ->
        {:error, %{error: :spawn_failed, exit_status: 1, output: "error: no session"}}
      end

      assert {:error, %{error: :spawn_failed, exit_status: 1}} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "codex",
                 task_slug: "x",
                 runner: runner
               )
    end

    test "runner without pane_id is invalid_spawn_result" do
      runner = fn _, _, _, _ -> {:ok, %{window_name: "worker-x"}} end

      assert {:error, %{error: :invalid_spawn_result}} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "claude",
                 task_slug: "x",
                 runner: runner
               )
    end

    test "dry_run never claims a live pane" do
      runner = fn _, slug, _, opts ->
        assert opts[:dry_run] == true
        {:ok, %{dry_run: true, window_name: "worker-#{slug}", plan_text: "session=x"}}
      end

      assert {:ok, plan} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "grok",
                 task_slug: "plan-me",
                 dry_run: true,
                 runner: runner
               )

      assert plan.dry_run == true
      assert plan.visible? == false
      refute Map.has_key?(plan, :pane_id)
    end
  end
end
