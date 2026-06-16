defmodule DevIDE.Terminals.BoundaryTest do
  use ExUnit.Case, async: false

  alias DevIDE.Audit
  alias DevIDE.Workspace
  alias DevIDE.Runners
  alias DevIDE.Runs.Ledger
  alias DevIDE.Terminals.Boundary
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    MemoryAdapter.clear()
    Runners.clear()
    Audit.clear()

    prev_default = Application.get_env(:dev_ide, :default_workspace_mode)
    prev_overrides = Application.get_env(:dev_ide, :workspace_modes)
    prev_allow_raw = Application.get_env(:dev_ide, :allow_local_raw_terminal)
    prev_raw_everywhere = Application.get_env(:dev_ide, :raw_terminal_everywhere)
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    root = Path.join(System.tmp_dir!(), "devide-boundary-test")
    workspace_path = Path.join(root, "ws-1")
    File.rm_rf!(root)
    File.mkdir_p!(workspace_path)
    File.write!(Path.join(workspace_path, "README.md"), "hello\n")

    Application.put_env(:dev_ide, :workspaces_root, root)
    Application.put_env(:dev_ide, :default_workspace_mode, :review)
    Application.delete_env(:dev_ide, :workspace_modes)

    on_exit(fn ->
      MemoryAdapter.clear()
      Runners.clear()
      Audit.clear()
      File.rm_rf(root)
      restore(:workspaces_root, prev_root)
      restore(:default_workspace_mode, prev_default)
      restore(:workspace_modes, prev_overrides)
      restore(:allow_local_raw_terminal, prev_allow_raw)
      restore(:raw_terminal_everywhere, prev_raw_everywhere)
    end)

    seed_workspace("ws-1", workspace_path)
    {:ok, workspace_path: workspace_path}
  end

  test "governed terminal resolves only allowlisted safe commands" do
    assert {:ok, "test"} = Boundary.resolve_command("mix test")
    assert {:ok, "test"} = Boundary.resolve_command("mix test --color")
    assert {:ok, "compile"} = Boundary.resolve_command("compile")
    assert {:ok, "format"} = Boundary.resolve_command("mix format --check-formatted")

    assert {:error, :not_allowed} = Boundary.resolve_command("mix format")
    assert {:error, :not_allowed} = Boundary.resolve_command("mix test test/foo_test.exs")
    assert {:error, :not_allowed} = Boundary.resolve_command("rm -rf priv/")
  end

  test "governed terminal resolver rejects interactive launchers" do
    assert "agent" in Boundary.interactive_command_ids()

    for command <- Boundary.interactive_command_ids() do
      assert {:error, :requires_raw_terminal} = Boundary.resolve_command(command)
    end
  end

  test "governed terminal resolver routes interactive launchers with arguments to raw" do
    for line <- ["claude --resume", "grok -m foo", ~s(codex exec "do a thing")] do
      assert {:error, :requires_raw_terminal} = Boundary.resolve_command(line)
    end
  end

  test "allowed governed terminal command enqueues runner assignment and audits allow" do
    assert {:ok, assignment} =
             Boundary.submit_governed("ws-1", "mix test", actor_id: "user-1")

    assert assignment.safe_action_id == "command:test"
    assert assignment.status == "queued"
    assert assignment.action.argv == ["mix", "test", "--color"]

    [queued, requested] = Ledger.recent_for("ws-1", 5)
    assert queued.action == "run.queued"
    assert queued.decision == :allow
    assert queued.target_type == "run"
    assert queued.metadata["command_id"] == "test"
    assert queued.metadata["assignment_id"] == assignment.id
    assert queued.target_ref == requested.metadata["run_id"]

    assert requested.action == "run.command_requested"
    assert requested.target_type == "command"
    assert requested.target_ref == "test"
    assert requested.metadata["run_id"] == queued.metadata["run_id"]
  end

  test "governed terminal submission rejects interactive launchers before enqueue" do
    for command <- ["agent", "grok"] do
      Audit.clear()

      assert {:error, :requires_raw_terminal} =
               Boundary.submit_governed("ws-1", command, actor_id: "user-1")

      [event] = Ledger.recent_for("ws-1", 5)
      assert event.action == "run.command_denied"
      assert event.decision == :deny
      assert event.reason == :requires_raw_terminal
      assert event.target_ref == command
      assert event.metadata["reason"] == "requires_raw_terminal"
    end
  end

  test "governed terminal accepts repository workflow commands", %{workspace_path: workspace_path} do
    write_workflow(workspace_path, "focused-test.yaml", """
    name: Run focused test
    command: mix test {{test_file}}
    description: Runs one test file through a governed workflow.
    arguments:
      - name: test_file
    """)

    assert {:ok, assignment} =
             Boundary.submit_governed("ws-1", "mix test test/dev_ide/commands_test.exs",
               actor_id: "user-1"
             )

    assert String.starts_with?(assignment.safe_action_id, "command:workflow:")
    assert assignment.status == "queued"
    assert assignment.action.argv == ["mix", "test", "test/dev_ide/commands_test.exs"]
    assert assignment.action.description =~ "Run repository workflow Run focused test"

    [queued, requested] = Ledger.recent_for("ws-1", 5)
    assert queued.action == "run.queued"
    assert queued.decision == :allow
    assert queued.metadata["command_id"] == assignment.action.command_id
    assert requested.target_type == "command"
    assert requested.target_ref == assignment.action.command_id

    assert {:ok, claimed} =
             Runners.poll(%{
               "protocol" => Runners.protocol(),
               "runner_id" => "runner-a",
               "capabilities" => ["workspace-command:v1"],
               "workspace_ids" => ["ws-1"]
             })

    assert claimed.safe_action_id == assignment.safe_action_id
    assert claimed.action.argv == ["mix", "test", "test/dev_ide/commands_test.exs"]
  end

  test "governed workflow arguments reject path traversal", %{workspace_path: workspace_path} do
    write_workflow(workspace_path, "focused-test.yaml", """
    name: Run focused test
    command: mix test {{test_file}}
    arguments:
      - name: test_file
    """)

    assert {:error, :not_allowed} =
             Boundary.submit_governed("ws-1", "mix test ../secret_test.exs", actor_id: "user-1")

    [event] = Ledger.recent_for("ws-1", 5)
    assert event.action == "run.command_denied"
    assert event.decision == :deny
  end

  test "denied governed terminal command creates policy audit row" do
    assert {:error, :not_allowed} =
             Boundary.submit_governed("ws-1", "rm -rf priv/", actor_id: "user-1")

    [event] = Ledger.recent_for("ws-1", 5)
    assert event.action == "run.command_denied"
    assert event.decision == :deny
    assert event.reason == :not_allowed
    assert event.target_type == "command"
    assert event.target_ref == "rm -rf priv/"
    assert event.metadata["plane"] == "governed"
  end

  test "governed terminal runs read-only inspection commands immediately" do
    assert {:ok, %{kind: :inspection, status: "completed", output: output}} =
             Boundary.submit_governed("ws-1", "ls", actor_id: "user-1")

    assert output =~ "README.md"

    [event] = Ledger.recent_for("ws-1", 5)
    assert event.action == "run.command_requested"
    assert event.decision == :allow
    assert event.target_ref == "ls"
    assert event.metadata["plane"] == "governed_inspection"
  end

  test "command examples include inspection commands" do
    examples = Boundary.command_examples()

    assert "tidewave" in examples
    assert "git status --short" in examples
  end

  test "command examples hide interactive launchers when raw shell is unavailable" do
    examples = Boundary.command_examples(raw_available?: false)

    assert "mix test" in examples
    assert "git status --short" in examples

    for command <- Boundary.interactive_command_ids() do
      refute command in examples
    end
  end

  test "command examples include interactive launchers when raw shell is available" do
    examples = Boundary.command_examples(raw_available?: true)

    for command <- Boundary.interactive_command_ids() do
      assert command in examples
    end
  end

  test "governed terminal reports tidewave debug status from workspace metadata" do
    assert {:ok, %{kind: :inspection, status: "completed", output: output}} =
             Boundary.submit_governed("ws-1", "tidewave", actor_id: "user-1")

    assert output =~ "Tidewave: detected"
    assert output =~ "https://tidewave.alice.workspaces.example.com"
    assert output =~ "port: 11003"

    [event] = Ledger.recent_for("ws-1", 5)
    assert event.action == "run.command_requested"
    assert event.target_ref == "tidewave"
    assert event.metadata["plane"] == "governed_inspection"
  end

  test "governed inspection rejects path traversal" do
    assert {:error, :outside_root} =
             Boundary.submit_governed("ws-1", "ls ../", actor_id: "user-1")

    [event] = Ledger.recent_for("ws-1", 5)
    assert event.action == "run.command_denied"
    assert event.reason == :outside_root
  end

  test "raw terminal is allowed from any workspace, mode, and host by default" do
    # default config: :raw_terminal_everywhere is enabled
    assert Boundary.raw_allowed?("ws-1", "local")
    assert Boundary.raw_allowed?("ws-1", "remote")
    assert :ok = Boundary.authorize_raw("ws-1", actor_id: "user-1", host_id: "remote")

    [allowed] = Ledger.recent_for("ws-1", 5)
    assert allowed.action == "run.session_attached"
    assert allowed.decision == :allow
    assert allowed.target_type == "session"
  end

  test "raw terminal re-tightens to manual mode on local host when disabled" do
    Application.put_env(:dev_ide, :raw_terminal_everywhere, false)

    refute Boundary.raw_allowed?("ws-1", "local")
    assert {:error, :requires_manual_mode} = Boundary.authorize_raw("ws-1", host_id: "local")

    Audit.clear()
    {:ok, _} = State.set_mode("ws-1", :manual)

    assert Boundary.raw_allowed?("ws-1", "local")
    assert :ok = Boundary.authorize_raw("ws-1", actor_id: "user-1", host_id: "local")
    assert {:error, :requires_local_host} = Boundary.authorize_raw("ws-1", host_id: "remote")

    [denied, allowed] = Ledger.recent_for("ws-1", 5)
    assert denied.action == "run.session_denied"
    assert denied.reason == :requires_local_host
    assert allowed.action == "run.session_attached"
    assert allowed.decision == :allow
    assert allowed.target_type == "session"
  end

  test "raw terminal does not allow local override without manual mode when re-tightened" do
    Application.put_env(:dev_ide, :raw_terminal_everywhere, false)
    Application.put_env(:dev_ide, :allow_local_raw_terminal, true)

    refute Boundary.raw_allowed?("ws-1", "local")
    assert {:error, :requires_manual_mode} = Boundary.authorize_raw("ws-1", host_id: "local")
  end

  defp seed_workspace(id, path) do
    {:ok, _} =
      State.sync(%Workspace{
        id: id,
        name: "alpha",
        user: "alice",
        branch: "main",
        status: :running,
        path: path,
        metadata: %{
          "id" => id,
          "ports" => %{"tidewave" => 11_003},
          "domain_base" => "alice.workspaces.example.com"
        }
      })
  end

  defp write_workflow(root, name, body) do
    dir = Path.join(root, ".dev_ide/workflows")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), body)
  end

  defp restore(k, nil), do: Application.delete_env(:dev_ide, k)
  defp restore(k, v), do: Application.put_env(:dev_ide, k, v)
end
