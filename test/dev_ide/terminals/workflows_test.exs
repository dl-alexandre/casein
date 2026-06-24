defmodule DevIDE.Terminals.WorkflowsTest do
  use ExUnit.Case, async: false

  alias DevIDE.Workspace
  alias DevIDE.Terminals.Workflows
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  @ws "ws-1"

  setup do
    MemoryAdapter.clear()

    root =
      Path.join(System.tmp_dir!(), "devide-workflows-test-#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, ".dev_ide/workflows"))
    File.mkdir_p!(Path.join(root, ".warp/workflows"))

    File.write!(Path.join(root, ".dev_ide/workflows/deploy.yaml"), """
    name: Deploy
    command: ./scripts/deploy.sh {{env}}
    description: Deploy the app
    arguments:
      - name: env
    """)

    File.write!(Path.join(root, ".dev_ide/workflows/status.yml"), """
    # a comment line
    ---
    name: Status
    command: git status
    """)

    # description before command so the block scalar is flushed by the
    # following non-indented line (a trailing block is otherwise dropped).
    File.write!(Path.join(root, ".warp/workflows/note.yaml"), """
    name: Note
    description: |-
      first line
      second line
    command: echo hello
    """)

    # A file with no command field is skipped entirely.
    File.write!(Path.join(root, ".dev_ide/workflows/broken.yaml"), """
    name: Broken
    description: no command here
    """)

    # A non-yaml file is ignored by the directory scan.
    File.write!(Path.join(root, ".dev_ide/workflows/readme.txt"), "ignore me\n")

    {:ok, _} =
      State.sync(%Workspace{
        id: @ws,
        name: "alpha",
        user: "alice",
        branch: "main",
        status: :running,
        path: root,
        metadata: %{"id" => @ws}
      })

    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root}
  end

  describe "list_specs/1" do
    test "parses workflow files from both workflow dirs" do
      specs = Workflows.list_specs(@ws)
      ids = Enum.map(specs, & &1.id) |> Enum.sort()

      assert "deploy" in ids
      assert "status" in ids
      assert "note" in ids
      # No command -> skipped.
      refute "broken" in ids
    end

    test "extracts declared and placeholder arguments" do
      deploy = Enum.find(Workflows.list_specs(@ws), &(&1.id == "deploy"))

      assert deploy.name == "Deploy"
      assert deploy.command == "./scripts/deploy.sh {{env}}"
      assert deploy.description == "Deploy the app"
      assert deploy.arguments == ["env"]
    end

    test "parses block scalar description and defaults missing description" do
      note = Enum.find(Workflows.list_specs(@ws), &(&1.id == "note"))
      status = Enum.find(Workflows.list_specs(@ws), &(&1.id == "status"))

      # Block scalar joins lines; only the whole value is trimmed, so the
      # second line keeps its relative indentation.
      assert note.description == "first line\n  second line"
      assert status.description =~ "Run repository workflow status"
      assert status.arguments == []
    end

    test "returns [] for unknown or non-binary workspace" do
      assert Workflows.list_specs("missing") == []
      assert Workflows.list_specs(nil) == []
      assert Workflows.list_specs(123) == []
    end
  end

  describe "palette_runnable?/1" do
    test "true only when no arguments are required" do
      assert Workflows.palette_runnable?(%{arguments: []})
      refute Workflows.palette_runnable?(%{arguments: ["env"]})
    end
  end

  describe "command_id/1 and list_command_ids/0" do
    test "command_id encodes the workflow prefix" do
      spec = Enum.find(Workflows.list_specs(@ws), &(&1.id == "deploy"))
      assert "workflow:" <> _ = Workflows.command_id(spec)
    end

    test "list_command_ids spans seeded workspaces" do
      ids = Workflows.list_command_ids()
      assert Enum.any?(ids, &String.starts_with?(&1, "workflow:"))
      assert length(ids) >= 3
    end
  end

  describe "resolve_line/2" do
    test "matches a templated command and returns an encoded id" do
      assert {:ok, "workflow:" <> _} =
               Workflows.resolve_line(@ws, "./scripts/deploy.sh staging")
    end

    test "matches a literal command with no arguments" do
      assert {:ok, "workflow:" <> _} = Workflows.resolve_line(@ws, "git status")
    end

    test "rejects commands that match no workflow" do
      assert {:error, :not_allowed} = Workflows.resolve_line(@ws, "rm -rf /")
    end

    test "rejects unsafe argument bindings (path traversal)" do
      assert {:error, :not_allowed} =
               Workflows.resolve_line(@ws, "./scripts/deploy.sh ../../etc/passwd")
    end

    test "rejects non-binary input" do
      assert {:error, :not_allowed} = Workflows.resolve_line(nil, "x")
      assert {:error, :not_allowed} = Workflows.resolve_line(@ws, nil)
    end
  end

  describe "fetch_command/1" do
    test "round-trips an encoded command id back to argv" do
      spec = Enum.find(Workflows.list_specs(@ws), &(&1.id == "deploy"))
      id = Workflows.command_id(spec)

      assert {:ok, cmd} = Workflows.fetch_command(id)
      assert cmd.command_id == id
      assert cmd.argv == ["./scripts/deploy.sh", "env"]
      assert cmd.description =~ "Run repository workflow Deploy"
    end

    test "returns :error for malformed ids" do
      assert :error = Workflows.fetch_command("not-a-workflow")
      assert :error = Workflows.fetch_command("workflow:!!!not-base64!!!")
      assert :error = Workflows.fetch_command(:nope)
    end
  end
end
