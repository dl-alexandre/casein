defmodule Casein.Terminals.InspectionCommandsTest do
  # Serial: mutates process-global Application env (:preview_env_home).
  use Casein.TestCase, async: false

  alias Casein.Terminals.InspectionCommands

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
    assert output =~ "preview-env.sh up"
  end

  test "run lists active preview env Tidewave MCP URLs when registry has runners" do
    home =
      Path.join(
        System.tmp_dir!(),
        "devide-preview-inspection-#{System.unique_integer([:positive])}"
      )

    inst_dir = Path.join(home, "instances")
    File.mkdir_p!(inst_dir)

    File.write!(
      Path.join(inst_dir, "prev-abc.json"),
      Jason.encode!(%{
        "id" => "prev-abc",
        "port" => "41042",
        "status" => "running",
        "tidewave_mcp_url" => "http://127.0.0.1:41042/tidewave/mcp"
      })
    )

    prev_home = Application.get_env(:dev_ide, :preview_env_home)
    Application.put_env(:dev_ide, :preview_env_home, home)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_preview_home(prev_home)
    end)

    assert {:ok, %{status: "completed", output: output}} =
             InspectionCommands.run("/tmp", "tidewave")

    assert output =~ "Active preview environments"
    assert output =~ "prev-abc"
    assert output =~ "http://127.0.0.1:41042/tidewave/mcp"
  end

  test "run reports detected tidewave from workspace metadata", %{root: root} do
    workspace = %{
      metadata: %{ports: %{"tidewave" => 11_990}, domain_base: "acme.workspaces.example.com"}
    }

    assert {:ok, %{status: "completed", output: output, argv: ["tidewave"]}} =
             InspectionCommands.run(root, "tidewave", workspace: workspace)

    assert output =~ "Tidewave: detected"
    assert output =~ "https://tidewave.acme.workspaces.example.com"
    assert output =~ "port: 11990"
    assert output =~ "https://tidewave.acme.workspaces.example.com/tidewave/mcp"
  end

  test "run rejects unsupported command", %{root: root} do
    assert {:error, :not_allowed} = InspectionCommands.run(root, "rm -rf")
  end

  test "run rejects non-root directories", %{root: root} do
    assert {:error, :no_root} = InspectionCommands.run(Path.join(root, "missing"), "pwd")
    File.rm_rf!(root)
    assert {:error, :no_root} = InspectionCommands.run(root, "pwd")
  end

  defp restore_preview_home(nil), do: Application.delete_env(:dev_ide, :preview_env_home)
  defp restore_preview_home(value), do: Application.put_env(:dev_ide, :preview_env_home, value)
end
