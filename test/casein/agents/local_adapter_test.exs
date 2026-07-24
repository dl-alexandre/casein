defmodule Casein.Agents.LocalAdapterTest do
  use Casein.TestCase, async: true
  alias Casein.Agents.LocalAdapter

  setup do
    root = Path.join(System.tmp_dir!(), "agents-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "filesystem capabilities are missing on a bare workspace", %{root: root} do
    caps = LocalAdapter.detect(root, nil)
    kinds = Enum.map(caps, & &1.kind) |> Enum.sort()

    assert kinds == [
             :artifact_mcp,
             :browser_artifacts,
             :fff,
             :opencode,
             :preview_mcp,
             :terminal_mcp,
             :tidewave
           ]

    preview_mcp = Enum.find(caps, &(&1.kind == :preview_mcp))
    assert preview_mcp.status == :detected
    assert preview_mcp.source == :casein
    assert preview_mcp.url =~ "/api/preview/mcp"
    assert "preview_open_app" in preview_mcp.details.tools
    assert "preview_close" in preview_mcp.details.tools

    artifact_mcp = Enum.find(caps, &(&1.kind == :artifact_mcp))
    assert artifact_mcp.status == :detected
    assert artifact_mcp.source == :casein
    assert artifact_mcp.url =~ "/api/artifacts/mcp"
    assert "artifact_create" in artifact_mcp.details.tools
    assert "artifact_update" in artifact_mcp.details.tools

    terminal_mcp = Enum.find(caps, &(&1.kind == :terminal_mcp))
    assert terminal_mcp.status == :detected
    assert terminal_mcp.source == :casein
    assert terminal_mcp.url =~ "/api/terminals/mcp"
    assert "terminal_list_sessions" in terminal_mcp.details.tools
    assert "terminal_capture" in terminal_mcp.details.tools

    # The Casein-hosted MCP capabilities are always detected; everything else
    # is filesystem/manager driven and missing on a bare workspace.
    assert caps
           |> Enum.reject(&(&1.kind in [:artifact_mcp, :preview_mcp, :terminal_mcp]))
           |> Enum.all?(&(&1.status == :missing))
  end

  test "detects opencode via .opencode/ dir", %{root: root} do
    File.mkdir_p!(Path.join(root, ".opencode"))
    caps = LocalAdapter.detect(root, nil)
    oc = Enum.find(caps, &(&1.kind == :opencode))
    assert oc.status == :detected
    assert oc.source == :workspace_fs
    assert oc.path == ".opencode"
  end

  test "detects browser artifacts only when subdirs present", %{root: root} do
    File.mkdir_p!(Path.join(root, ".agent"))
    caps_empty = LocalAdapter.detect(root, nil)
    assert Enum.find(caps_empty, &(&1.kind == :browser_artifacts)).status == :missing

    File.mkdir_p!(Path.join([root, ".agent", "screenshots"]))
    caps_full = LocalAdapter.detect(root, nil)
    ba = Enum.find(caps_full, &(&1.kind == :browser_artifacts))
    assert ba.status == :detected
    assert "screenshots" in ba.details.subdirs
  end

  test "detects tidewave from explicit ports + domain_base in metadata", %{root: root} do
    ws = %{
      metadata: %{
        ports: %{"tidewave" => 11_003},
        domain_base: "alice.workspaces.example.com"
      }
    }

    caps = LocalAdapter.detect(root, ws)
    tw = Enum.find(caps, &(&1.kind == :tidewave))
    assert tw.status == :detected
    assert tw.url =~ "tidewave.alice.workspaces.example.com"
    assert tw.details.port == 11_003
    assert tw.details.mcp_url == "https://tidewave.alice.workspaces.example.com/tidewave/mcp"
  end

  test "detects tidewave from persisted string-key metadata", %{root: root} do
    ws = %{
      metadata: %{
        "ports" => %{"tidewave" => 11_003},
        "domain_base" => "alice.workspaces.example.com"
      }
    }

    caps = LocalAdapter.detect(root, ws)
    tw = Enum.find(caps, &(&1.kind == :tidewave))
    assert tw.status == :detected
    assert tw.url == "https://tidewave.alice.workspaces.example.com"
    assert tw.details.port == 11_003
    assert tw.details.mcp_url == "https://tidewave.alice.workspaces.example.com/tidewave/mcp"
  end

  test "detects tidewave from fingerprinted metadata ports", %{root: root} do
    ws = %{
      metadata: %{
        tidewave_ports: [
          %{
            port: 5173,
            url: "http://127.0.0.1:5173/tidewave",
            mcp_url: "http://127.0.0.1:5173/tidewave/mcp"
          }
        ]
      }
    }

    caps = LocalAdapter.detect(root, ws)
    tw = Enum.find(caps, &(&1.kind == :tidewave))
    assert tw.status == :detected
    assert tw.source == :workspace_fs
    assert tw.details.fingerprint
    assert tw.details.mcp_url == "http://127.0.0.1:5173/tidewave/mcp"
  end

  test "tidewave missing without manager hints", %{root: root} do
    caps = LocalAdapter.detect(root, %{metadata: %{}})
    assert Enum.find(caps, &(&1.kind == :tidewave)).status == :missing
  end

  test "transcripts returns [] when no session dirs exist", %{root: root} do
    assert LocalAdapter.transcripts(root) == []
  end

  test "transcripts lists files under .opencode/sessions", %{root: root} do
    File.mkdir_p!(Path.join([root, ".opencode", "sessions"]))
    File.write!(Path.join([root, ".opencode", "sessions", "a.json"]), "{}")
    File.write!(Path.join([root, ".opencode", "sessions", "b.log"]), "x")
    files = LocalAdapter.transcripts(root)
    names = Enum.map(files, & &1.name) |> Enum.sort()
    assert names == ["a.json", "b.log"]
  end

  test "detection refuses to read outside the workspace root", %{root: _root} do
    # If a malicious path escape is attempted via `Agents.detect`, the
    # adapter never receives anything but the manager-supplied root, and
    # all FS calls go through PathSafety. This regression guard ensures
    # the adapter does not gain new code paths that bypass that.
    src =
      File.read!(
        Path.join([__DIR__, "..", "..", "..", "lib", "casein", "agents", "local_adapter.ex"])
      )

    refute src =~ "File.read!"
    refute src =~ "File.cd"
    refute src =~ "System.cmd"
  end
end
