defmodule DevIDE.Agents.TidewaveMCPTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Agents.TidewaveMCP

  setup do
    prev_home = Application.get_env(:dev_ide, :preview_env_home)
    prev_env_url = System.get_env("DEVIDE_TIDEWAVE_MCP_URL")
    prev_preview_env_id = System.get_env("DEVIDE_PREVIEW_ENV_ID")

    System.delete_env("DEVIDE_TIDEWAVE_MCP_URL")
    System.delete_env("DEVIDE_PREVIEW_ENV_ID")

    on_exit(fn ->
      restore_preview_home(prev_home)

      if prev_env_url,
        do: System.put_env("DEVIDE_TIDEWAVE_MCP_URL", prev_env_url),
        else: System.delete_env("DEVIDE_TIDEWAVE_MCP_URL")

      if prev_preview_env_id,
        do: System.put_env("DEVIDE_PREVIEW_ENV_ID", prev_preview_env_id),
        else: System.delete_env("DEVIDE_PREVIEW_ENV_ID")
    end)

    :ok
  end

  test "normalize_mcp_url appends /tidewave/mcp when needed" do
    assert TidewaveMCP.normalize_mcp_url("http://127.0.0.1:41042") ==
             "http://127.0.0.1:41042/tidewave/mcp"

    assert TidewaveMCP.normalize_mcp_url("http://127.0.0.1:41042/tidewave") ==
             "http://127.0.0.1:41042/tidewave/mcp"

    assert TidewaveMCP.normalize_mcp_url("http://127.0.0.1:41042/tidewave/mcp") ==
             "http://127.0.0.1:41042/tidewave/mcp"
  end

  test "resolve_url prefers explicit option override" do
    url =
      TidewaveMCP.resolve_url(
        %{metadata: %{ports: %{"tidewave" => 11_003}, domain_base: "acme.example.com"}},
        tidewave_mcp_url: "http://override.example/tidewave"
      )

    assert url == "http://override.example/tidewave/mcp"
  end

  test "resolve_url uses workspace manager metadata" do
    workspace = %{
      metadata: %{
        domain_base: "acme.workspaces.example.com",
        ports: %{"tidewave" => 11_003}
      }
    }

    assert TidewaveMCP.resolve_url(workspace, preview_env_fallback: false) ==
             "https://tidewave.acme.workspaces.example.com/tidewave/mcp"
  end

  test "resolve_url uses fingerprinted tidewave_ports metadata" do
    workspace = %{
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

    assert TidewaveMCP.resolve_url(workspace, preview_env_fallback: false) ==
             "http://127.0.0.1:5173/tidewave/mcp"
  end

  test "resolve_url falls back to running preview registry instance" do
    home =
      Path.join(
        System.tmp_dir!(),
        "devide-tidewave-mcp-#{System.unique_integer([:positive])}"
      )

    inst_dir = Path.join(home, "instances")
    File.mkdir_p!(inst_dir)

    File.write!(
      Path.join(inst_dir, "prev-abc.json"),
      Jason.encode!(%{
        "id" => "prev-abc",
        "port" => "41042",
        "status" => "running",
        "started_at" => "2026-06-18T12:00:00Z"
      })
    )

    Application.put_env(:dev_ide, :preview_env_home, home)

    on_exit(fn -> File.rm_rf!(home) end)

    assert TidewaveMCP.resolve_url(%{}, preview_env_fallback: true) ==
             "http://127.0.0.1:41042/tidewave/mcp"
  end

  test "resolve_url skips registry when preview_env_fallback is false" do
    home =
      Path.join(
        System.tmp_dir!(),
        "devide-tidewave-mcp-off-#{System.unique_integer([:positive])}"
      )

    inst_dir = Path.join(home, "instances")
    File.mkdir_p!(inst_dir)

    File.write!(
      Path.join(inst_dir, "prev-abc.json"),
      Jason.encode!(%{"id" => "prev-abc", "port" => "41042", "status" => "running"})
    )

    Application.put_env(:dev_ide, :preview_env_home, home)

    on_exit(fn -> File.rm_rf!(home) end)

    assert TidewaveMCP.resolve_url(%{}, preview_env_fallback: false) == nil
  end

  test "server_key slugifies workspace name" do
    assert TidewaveMCP.server_key(%{name: "Alice Feature"}) == "devide-tidewave-alice-feature"
  end

  defp restore_preview_home(nil), do: Application.delete_env(:dev_ide, :preview_env_home)
  defp restore_preview_home(value), do: Application.put_env(:dev_ide, :preview_env_home, value)
end
