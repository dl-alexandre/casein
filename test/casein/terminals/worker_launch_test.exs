defmodule Casein.Terminals.WorkerLaunchTest do
  use ExUnit.Case, async: false

  alias Casein.Terminals.IssueBinding
  alias Casein.Terminals.AgentState
  alias Casein.Terminals.WorkerLaunch
  alias Casein.Terminals.WorkHandles

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

    test "default runner resolves a configured runtime tree before stale scripts env" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "worker-launch-runtime-#{System.unique_integer([:positive])}"
        )

      scripts = Path.join(tmp, "scripts")
      checkout = Path.join(tmp, "checkout")
      File.mkdir_p!(scripts)
      File.mkdir_p!(checkout)

      script = Path.join(scripts, "spawn-agent-worker.sh")

      File.write!(script, """
      #!/usr/bin/env bash
      printf 'workspace=%s\\nsession=%s\\ncheckout=%s\\n' \\
        "${CASEIN_WORKSPACE_ID:-}" "${CASEIN_TMUX_SESSION:-}" "${CASEIN_CHECKOUT:-}"
      """)

      previous =
        for key <- [
              "CASEIN_SPAWN_WORKER_SCRIPT",
              "CASEIN_SCRIPTS_ROOT",
              "CASEIN_SCRIPTS",
              "CASEIN_CHECKOUT"
            ],
            into: %{} do
          {key, System.get_env(key)}
        end

      on_exit(fn ->
        restore_env(previous, "CASEIN_SPAWN_WORKER_SCRIPT")
        restore_env(previous, "CASEIN_SCRIPTS_ROOT")
        restore_env(previous, "CASEIN_SCRIPTS")
        restore_env(previous, "CASEIN_CHECKOUT")
        File.rm_rf(tmp)
      end)

      System.delete_env("CASEIN_SPAWN_WORKER_SCRIPT")
      System.put_env("CASEIN_SCRIPTS_ROOT", scripts)
      System.put_env("CASEIN_SCRIPTS", Path.join(tmp, "missing-scripts"))
      System.put_env("CASEIN_CHECKOUT", checkout)

      assert {:ok, plan} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "opencode",
                 task_slug: "runtime-resolution",
                 dry_run: true
               )

      assert plan.plan.script == script
      assert plan.plan.plan_text =~ "workspace=#{@ws}"
      assert plan.plan.plan_text =~ "session=#{@session}"
      assert plan.plan.plan_text =~ "checkout=#{checkout}"
    end

    test "default runner uses an explicit checkout for the command working directory" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "worker-launch-checkout-#{System.unique_integer([:positive])}"
        )

      scripts = Path.join(tmp, "scripts")
      checkout = Path.join(tmp, "checkout")
      stale = Path.join(tmp, "missing-checkout")
      File.mkdir_p!(scripts)
      File.mkdir_p!(checkout)

      script = Path.join(scripts, "spawn-agent-worker.sh")

      File.write!(script, """
      #!/usr/bin/env bash
      printf 'cwd=%s\\ncheckout=%s\\n' "$PWD" "$CASEIN_CHECKOUT"
      """)

      previous = System.get_env("CASEIN_CHECKOUT")

      on_exit(fn ->
        case previous do
          nil -> System.delete_env("CASEIN_CHECKOUT")
          value -> System.put_env("CASEIN_CHECKOUT", value)
        end

        File.rm_rf(tmp)
      end)

      System.put_env("CASEIN_CHECKOUT", stale)

      assert {:ok, plan} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "codex",
                 task_slug: "explicit-checkout",
                 checkout: checkout,
                 scripts_root: scripts,
                 dry_run: true
               )

      assert plan.plan.plan_text =~ "cwd=#{realpath!(checkout)}"
      assert plan.plan.plan_text =~ "checkout=#{checkout}"
    end
  end

  describe "launch/1 issue guard" do
    setup do
      IssueBinding.clear_all()
      on_exit(&IssueBinding.clear_all/0)
      :ok
    end

    test "refuses spawn when the issue is already held" do
      {:ok, _} = IssueBinding.bind(@ws, @session, "%1", 678, window_id: "@1")

      runner = fn _, _, _, _ ->
        flunk("runner must not run when the issue is already held")
      end

      assert {:error,
              %{
                error: :issue_already_bound,
                pane_id: "%1",
                window_id: "@1",
                issue: 678
              }} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "opencode",
                 task_slug: "dup",
                 issue: "678",
                 live?: fn _, _ -> true end,
                 runner: runner
               )
    end

    test "allow_duplicate launches and records both holders" do
      {:ok, _} = IssueBinding.bind(@ws, @session, "%1", 678, window_id: "@1")

      runner = fn _, slug, _, _ -> {:ok, %{pane_id: "%42", window_name: "worker-#{slug}"}} end
      observe = fn _, _ -> %{window_id: "@9"} end

      assert {:ok, receipt} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "opencode",
                 task_slug: "dup",
                 issue: 678,
                 allow_duplicate: true,
                 live?: fn _, _ -> true end,
                 runner: runner,
                 observe: observe,
                 attach_handle: false
               )

      assert receipt.issue == 678
      assert receipt.pane_id == "%42"
      assert Enum.sort(Enum.map(IssueBinding.holders(@ws, 678), & &1.pane_id)) == ["%1", "%42"]
    end

    test "binds the new pane when the issue is free" do
      runner = fn _, slug, _, _ -> {:ok, %{pane_id: "%42", window_name: "worker-#{slug}"}} end
      observe = fn _, _ -> %{window_id: "@9"} end

      assert {:ok, receipt} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "opencode",
                 task_slug: "free",
                 issue: "#678",
                 runner: runner,
                 observe: observe,
                 attach_handle: false
               )

      assert receipt.issue == 678
      assert %{issue: 678, window_id: "@9"} = IssueBinding.get(@session, "%42")
    end
  end

  describe "launch/1 receipt" do
    test "launch records the full worker association before delivering the first prompt" do
      WorkHandles.clear_all()
      AgentState.clear()

      on_exit(fn ->
        WorkHandles.clear_all()
        AgentState.clear()
      end)

      runner = fn _runtime, slug, _session, _opts ->
        {:ok, %{pane_id: "%42", window_name: "worker-#{slug}"}}
      end

      observe = fn _session, _pane ->
        %{
          window_id: "@9",
          window_name: "worker-session-reliability",
          worktree_path: "/tmp/casein-agent-worktrees/session-reliability",
          branch: "agent/opencode/session-reliability"
        }
      end

      set_label = fn workspace_id, session, pane, label, opts ->
        send(self(), {:label, workspace_id, session, pane, label, opts})
        :ok
      end

      deliver_prompt = fn session, pane, prompt, opts ->
        # The handle must already be inspectable before any prompt bytes move.
        assert [%{pane_id: ^pane, session: ^session}] = WorkHandles.list(@ws)
        send(self(), {:prompt, session, pane, prompt, opts})

        {:ok,
         %{
           delivery: :delivered,
           submitted: true,
           confirmation: :hook,
           enter_presses: 1
         }}
      end

      assert {:ok, receipt} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "opencode",
                 task_slug: "session-reliability",
                 label: "worker: session reliability",
                 initial_prompt: "Implement the scoped discovery fix.",
                 runner: runner,
                 observe: observe,
                 set_label: set_label,
                 deliver_prompt: deliver_prompt
               )

      assert receipt.prompt_delivery == %{
               status: "delivered",
               delivery: "delivered",
               submitted: true,
               confirmation: "hook",
               enter_presses: 1
             }

      assert_received {:label, @ws, @session, "%42", "worker: session reliability", opts}
      assert opts[:freeze] == true
      assert opts[:tool] == "worker_launch"

      assert_received {:prompt, @session, "%42", "Implement the scoped discovery fix.", _opts}

      assert {:ok, handle} = WorkHandles.get(receipt.handle_id)
      assert handle.runtime == "opencode"
      assert handle.task_slug == "session-reliability"
      assert handle.worktree_path == "/tmp/casein-agent-worktrees/session-reliability"
      assert handle.branch == "agent/opencode/session-reliability"
      assert handle.window_id == "@9"
      assert handle.window_name == "worker-session-reliability"

      topology =
        WorkHandles.enrich_topology(
          %{panes: [%{id: "%42", window_id: "@9"}], windows: []},
          @ws,
          @session
        )

      assert topology.work_handles_observe_state == "ok"
      assert [%{handle_id: handle_id}] = topology.work_handles
      assert handle_id == receipt.handle_id
      assert [%{work_handle: %{handle_id: ^handle_id, runtime: "opencode"}}] = topology.panes
    end

    test "an unconfirmed initial prompt fails loudly but keeps the worker receipt inspectable" do
      WorkHandles.clear_all()
      AgentState.clear()

      on_exit(fn ->
        WorkHandles.clear_all()
        AgentState.clear()
      end)

      runner = fn _, slug, _, _ ->
        {:ok, %{pane_id: "%43", window_name: "worker-#{slug}"}}
      end

      deliver_prompt = fn _, _, _, _ ->
        {:error,
         %{
           error: :submit_not_confirmed,
           delivery: :not_confirmed,
           submitted: false,
           confirmation: :unconfirmed
         }}
      end

      assert {:error, error} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "codex",
                 task_slug: "prompt-failed",
                 initial_prompt: "Do the work",
                 runner: runner,
                 observe: fn _, _ -> %{} end,
                 set_label: fn _, _, _, _, _ -> :ok end,
                 deliver_prompt: deliver_prompt
               )

      assert error.error == :initial_prompt_delivery_failed
      assert error.worker.pane_id == "%43"
      assert error.worker.prompt_delivery.status == "failed"
      assert is_binary(error.worker.handle_id)
      assert {:ok, %{status: %{state: "blocked"}}} = WorkHandles.get(error.worker.handle_id)
    end

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
      assert receipt.note =~ "Visible worker_launch receipt"
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

  test "managed OpenCode dry-run and launch keep workspace, session, git facts, and ledger identity" do
    integration_workspace = "37a50042-54ca-4a6b-9f89-aa21ae5bf623"
    integration_session = "casein_dalexandre-integration_coordinator"

    WorkHandles.clear_all()
    on_exit(fn -> WorkHandles.clear_all() end)

    dry_runner = fn runtime, slug, session, opts ->
      assert runtime == "opencode"
      assert slug == "integration-worker"
      assert session == integration_session
      assert opts[:dry_run]
      {:ok, %{dry_run: true, window_name: "worker-#{slug}"}}
    end

    assert {:ok, dry_plan} =
             WorkerLaunch.launch(
               workspace_id: integration_workspace,
               session: integration_session,
               runtime: "opencode",
               task_slug: "integration-worker",
               dry_run: true,
               runner: dry_runner
             )

    assert dry_plan.workspace_id == integration_workspace
    assert dry_plan.session == integration_session
    assert dry_plan.visible? == false
    refute Map.has_key?(dry_plan, :pane_id)

    runner = fn runtime, slug, session, _opts ->
      assert runtime == "opencode"
      assert slug == "integration-worker"
      assert session == integration_session
      {:ok, %{pane_id: "%77", window_name: "worker-#{slug}"}}
    end

    observe = fn session, pane_id ->
      assert session == integration_session
      assert pane_id == "%77"

      %{
        window_id: "@77",
        worktree_path: "/tmp/casein-agent-worktrees/dalexandre-integration/integration-worker",
        branch: "agent/opencode/integration-worker-20260820"
      }
    end

    assert {:ok, receipt} =
             WorkerLaunch.launch(
               workspace_id: integration_workspace,
               session: integration_session,
               runtime: "opencode",
               task_slug: "integration-worker",
               runner: runner,
               observe: observe
             )

    assert receipt.workspace_id == integration_workspace
    assert receipt.session == integration_session
    assert receipt.runtime == "opencode"

    assert receipt.worktree_path ==
             "/tmp/casein-agent-worktrees/dalexandre-integration/integration-worker"

    assert receipt.branch == "agent/opencode/integration-worker-20260820"
    assert is_binary(receipt.handle_id)

    assert {:ok, handle} = WorkHandles.get(receipt.handle_id)
    assert handle.workspace_id == integration_workspace
    assert handle.session == integration_session
    assert handle.pane_id == "%77"
    assert handle.label == "worker: integration-worker"
    assert handle.status.state == "awaiting_input"
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
    refused:headroom
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
      assert err.token == "refused:headroom"
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
      assert err.token == "refused:headroom"
      assert is_binary(err.reason) and err.reason != ""
      assert McpCtl.Error.summary(err) =~ "headroom"
    end

    test "exit 75 with refused:headroom token classifies without the prose phrase" do
      runner = fn _, _, _, _ ->
        {:error,
         %{
           error: :spawn_dry_run_failed,
           exit_status: 75,
           output:
             "refused:headroom\nprobe: load1=40.00 nproc=32 max_ratio=1.0 mem_available_kb=1000",
           message: "spawn dry-run failed (exit 75)"
         }}
      end

      assert {:error, err} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "grok",
                 task_slug: "token",
                 dry_run: true,
                 runner: runner
               )

      assert err.error == :spawn_headroom_exhausted
      assert err.token == "refused:headroom"
      assert err.load1 == "40.00"
      refute err.message == "spawn dry-run failed (exit 75)"
    end

    test "proceed:headroom-force is never classified as a refusal" do
      runner = fn _, _, _, _ ->
        {:error,
         %{
           error: :spawn_dry_run_failed,
           exit_status: 75,
           output:
             "proceed:headroom-force\nwarn: host headroom below threshold; proceeding under CASEIN_SPAWN_FORCE",
           message: "spawn dry-run failed (exit 75)"
         }}
      end

      assert {:error, err} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "claude",
                 task_slug: "force",
                 dry_run: true,
                 runner: runner
               )

      refute err.error == :spawn_headroom_exhausted
      refute Map.has_key?(err, :token)
      assert err.exit_status == 75
    end
  end

  describe "missing spawn helper is loud to MCP (OB #19287)" do
    test "dry_run names the helper and searched paths instead of exit 127" do
      missing =
        Path.join(
          System.tmp_dir!(),
          "no-such-spawn-#{System.unique_integer([:positive])}.sh"
        )

      assert {:error, err} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "claude",
                 task_slug: "probe",
                 dry_run: true,
                 spawn_script: missing
               )

      assert err.error == :spawn_script_not_found
      assert err.script == missing
      assert err.searched == [missing]
      refute Map.has_key?(err, :pane_id)
      refute err.message == "spawn dry-run failed (exit 127)"
      assert err.message =~ missing
      assert err.message =~ "Searched:"
      assert err.message =~ "in-workspace factory manager"
      assert err.message =~ "CASEIN_SPAWN_WORKER_SCRIPT"

      summary = McpCtl.Error.summary(err)
      refute summary == "spawn dry-run failed (exit 127)"
      assert summary =~ missing
      assert summary =~ "in-workspace factory manager"

      text = hd(McpCtl.Error.tool_result(err).content).text
      refute text == "spawn dry-run failed (exit 127)"
      assert text =~ missing
    end

    test "exit 127 is spawn_command_not_found with helper, paths, and in-workspace hint" do
      script = "/tmp/missing/spawn-agent-worker.sh"

      searched = [
        script,
        "/opt/casein/release/lib/casein-0.1.0/priv/scripts/spawn-agent-worker.sh"
      ]

      runner = fn _, _, _, _ ->
        {:error,
         %{
           error: :spawn_dry_run_failed,
           exit_status: 127,
           output: "bash: #{script}: No such file or directory",
           script: script,
           searched: searched,
           message: "spawn dry-run failed (exit 127)"
         }}
      end

      assert {:error, err} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "claude",
                 task_slug: "probe",
                 dry_run: true,
                 runner: runner
               )

      assert err.error == :spawn_command_not_found
      assert err.exit_status == 127
      assert err.script == script
      assert err.searched == searched
      refute err.message == "spawn dry-run failed (exit 127)"
      assert err.message =~ script
      assert err.message =~ "Searched:"
      assert err.message =~ "No such file or directory"
      assert err.message =~ "in-workspace factory manager"

      summary = McpCtl.Error.summary(err)
      refute summary == "spawn dry-run failed (exit 127)"
      assert summary =~ script
      assert summary =~ "in-workspace"

      text = hd(McpCtl.Error.tool_result(err).content).text
      refute text == "spawn dry-run failed (exit 127)"
      assert text =~ script
    end

    test "a non-127 spawn failure still includes output in the MCP message" do
      runner = fn _, _, _, _ ->
        {:error,
         %{
           error: :spawn_failed,
           exit_status: 1,
           output: "error: no session",
           message: "spawn-agent-worker.sh exited 1"
         }}
      end

      assert {:error, err} =
               WorkerLaunch.launch(
                 workspace_id: @ws,
                 session: @session,
                 runtime: "codex",
                 task_slug: "x",
                 runner: runner
               )

      assert err.error == :spawn_failed
      assert err.exit_status == 1
      refute err.message == "spawn-agent-worker.sh exited 1"
      assert err.message =~ "no session"
      assert McpCtl.Error.summary(err) =~ "no session"
    end
  end

  defp restore_env(previous, key) do
    case Map.fetch!(previous, key) do
      nil -> System.delete_env(key)
      value -> System.put_env(key, value)
    end
  end

  defp realpath!(path) do
    {out, 0} =
      System.cmd("python3", ["-c", "import os, sys; print(os.path.realpath(sys.argv[1]))", path])

    String.trim(out)
  end
end
