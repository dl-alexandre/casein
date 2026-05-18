defmodule DevIDE.Terminals.InspectionCommandsTest do
  use ExUnit.Case, async: true

  alias DevIDE.Terminals.InspectionCommands

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "devide-inspection-commands-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.write!(Path.join(root, "README.md"), "inspection\n")

    on_exit(fn -> File.rm_rf(root) end)

    %{root: root}
  end

  test "run executes supported read-only filesystem command", %{root: root} do
    assert {:ok, %{status: "completed", argv: argv, output: output}} =
             InspectionCommands.run(root, "ls")

    assert List.last(argv) == "-la"
    assert output =~ "README.md"
  end

  test "run rejects path traversal for ls", %{root: root} do
    assert {:error, :outside_root} = InspectionCommands.run(root, "ls ../")
    assert {:error, :outside_root} = InspectionCommands.run(root, "ls ../../etc")
  end

  test "run returns tidewave missing status when unavailable" do
    assert {:ok, %{status: "completed", output: output}} =
             InspectionCommands.run("/tmp", "tidewave")

    assert output =~ "Tidewave: missing"
    assert output =~ "Expected workspace metadata"
  end

  test "run reports missing tidewave when unavailable", %{root: root} do
    workspace = %{
      metadata: %{ports: %{"tidewave" => 11990}, domain_base: "acme.workspaces.example.com"}
    }

    assert {:ok, %{status: "completed", output: output, argv: ["tidewave"]}} =
             InspectionCommands.run(root, "tidewave", workspace: workspace)

    assert output =~ "Tidewave:"
    assert output =~ "Expected workspace metadata"
  end

  test "run rejects unsupported command", %{root: root} do
    assert {:error, :not_allowed} = InspectionCommands.run(root, "rm -rf")
  end

  test "run rejects non-root directories", %{root: root} do
    assert {:error, :no_root} = InspectionCommands.run(Path.join(root, "missing"), "pwd")
    File.rm_rf!(root)
    assert {:error, :no_root} = InspectionCommands.run(root, "pwd")
  end
end
