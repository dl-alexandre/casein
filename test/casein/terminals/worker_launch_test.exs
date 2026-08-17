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

  # Constraints in the artifact (not only the brief). If a later slice "helpfully"
  # adds hidden-subagent fallback, durable graph fields, or dry_run pane ids,
  # these fail first — briefs die with the pane (#384 / fleet signal-honesty).
  describe "contract: no silent product-principle undo" do
    test "success receipt never claims a hidden subagent" do
      runner = fn _, slug, _, _ -> {:ok, %{pane_id: "%7", window_name: "worker-#{slug}"}} end
      observe = fn _, _ -> %{} end

      assert {:ok, receipt} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "opencode",
                 task_slug: "contract",
                 runner: runner,
                 observe: observe,
                 attach_handle: false
               )

      assert receipt.hidden_subagent? == false
      assert receipt.visible? == true
      assert is_binary(receipt.pane_id)
    end

    test "receipt does not invent durable-graph / verifier fields (out of scope)" do
      runner = fn _, slug, _, _ -> {:ok, %{pane_id: "%8", window_name: "worker-#{slug}"}} end
      observe = fn _, _ -> %{} end

      assert {:ok, receipt} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "claude",
                 task_slug: "no-graph",
                 runner: runner,
                 observe: observe,
                 attach_handle: false
               )

      # do not grow M4-lite into orchestration_create by stealth — durable graph
      # / path contracts / verifiers stay on later #384 milestones.
      forbid = [
        :orchestration_id,
        :task_id,
        :attempt_id,
        :contract_version,
        :path_contract,
        :verifier_run_id,
        :evidence_packet
      ]

      for key <- forbid do
        refute Map.has_key?(receipt, key),
               "receipt must not carry #{key} (out of scope for worker_launch M4-lite)"
      end
    end

    test "spawn error never soft-succeeds with a fabricated pane" do
      runner = fn _, _, _, _ -> {:error, %{error: :spawn_failed, exit_status: 3}} end

      assert {:error, %{error: :spawn_failed}} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "codex",
                 task_slug: "fail",
                 runner: runner
               )
    end
  end

  describe "headroom refusal is loud to MCP (#970)" do
    @headroom_output """
    error: spawn refused — host headroom exhausted (#863)
           load1 40.00 exceeds nproc 32 × max_ratio 1.0
           probe: load1=40.00 nproc=32 max_ratio=1.0 mem_available_kb=37748736 min_mem_kb=2097152
           override: CASEIN_SPAWN_FORCE=1 bash scripts/spawn-agent-worker.sh ...
    """

    test "exit 75 with a headroom decline is spawn_headroom_exhausted, not a bare exit code" do
      runner = fn _, _, _, _ ->
        {:error,
         %{
           error: :spawn_dry_run_failed,
           exit_status: 75,
           output: @headroom_output,
           message: "spawn dry-run failed (exit 75)"
         }}
      end

      assert {:error, err} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "opencode",
                 task_slug: "headroom",
                 dry_run: true,
                 runner: runner
               )

      assert err.error == :spawn_headroom_exhausted
      assert err.exit_status == 75
      assert err.reason =~ "load1 40.00 exceeds nproc 32"
      assert err.load1 == "40.00"
      assert err.nproc == 32
      assert err.mem_available_kb == 37_748_736
      assert err.override == "CASEIN_SPAWN_FORCE=1"

      # MCP clients render McpCtl.Error.summary/1 (= message), not `output`.
      # A message that is only "spawn dry-run failed (exit 75)" is the defect.
      refute err.message == "spawn dry-run failed (exit 75)"
      assert err.message =~ "headroom exhausted"
      assert err.message =~ "load1 40.00 exceeds nproc 32"
      assert err.message =~ "CASEIN_SPAWN_FORCE=1"

      summary = McpCtl.Error.summary(err)
      assert summary =~ "headroom exhausted"
      assert summary =~ "load1 40.00 exceeds nproc 32"

      text = hd(McpCtl.Error.tool_result(err).content).text
      assert text =~ "headroom exhausted"
      assert text =~ "load1 40.00 exceeds nproc 32"
    end

    test "a headroom refusal without a reason string is a test failure, not a silent cap" do
      runner = fn _, _, _, _ ->
        {:error,
         %{
           error: :spawn_dry_run_failed,
           exit_status: 75,
           output:
             "error: spawn refused — host headroom exhausted (#863)\n       probe: load1=99 nproc=8 max_ratio=1.0 mem_available_kb=1000",
           message: "spawn dry-run failed (exit 75)"
         }}
      end

      assert {:error, err} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "claude",
                 task_slug: "quiet",
                 dry_run: true,
                 runner: runner
               )

      assert err.error == :spawn_headroom_exhausted
      assert is_binary(err.reason) and err.reason != ""
      assert McpCtl.Error.summary(err) =~ "headroom"
    end
  end
end
