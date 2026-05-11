defmodule DevIdeWeb.TerminalBoundaryLiveTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Audit
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    bypass = Bypass.open()
    workspace_root = Path.join(System.tmp_dir!(), "devide-terminal-live")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_manager = Application.get_env(:dev_ide, :manager_url)
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_default = Application.get_env(:dev_ide, :default_workspace_mode)
    prev_overrides = Application.get_env(:dev_ide, :workspace_modes)

    Application.put_env(:dev_ide, :manager_url, "http://localhost:#{bypass.port}")
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :default_workspace_mode, :review)
    Application.delete_env(:dev_ide, :workspace_modes)

    MemoryAdapter.clear()
    Audit.clear()

    Bypass.stub(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    on_exit(fn ->
      MemoryAdapter.clear()
      Audit.clear()
      File.rm_rf(workspace_root)
      restore(:manager_url, prev_manager)
      restore(:workspaces_root, prev_root)
      restore(:default_workspace_mode, prev_default)
      restore(:workspace_modes, prev_overrides)
    end)

    {:ok, workspace_path: workspace_path}
  end

  test "raw shell control is hidden until local workspace is manual", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/workspaces/ws-1?host=local")

    assert html =~ "Governed"
    refute html =~ "Raw shell"
    assert html =~ ~s(data-terminal-mode="governed")

    {:ok, _} = State.set_mode("ws-1", :manual)

    {:ok, _view, html} = live(conn, ~p"/workspaces/ws-1?host=local")

    assert html =~ "Raw shell"
    assert html =~ ~s(id="terminal-mode-raw")
    assert html =~ ~s(data-host-id="local")
  end

  test "non-local workspace route cannot expose raw shell", %{conn: conn} do
    {:ok, _} = State.set_mode("ws-1", :manual)

    assert {:error, {:live_redirect, %{to: "/workspaces", flash: flash}}} =
             live(conn, ~p"/workspaces/ws-1?host=remote")

    assert flash["error"] =~ "Cross-host attach is not yet configured"
  end

  defp workspace_payload(conn, workspace_path) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      200,
      Jason.encode!(%{
        "id" => "ws-1",
        "name" => "alpha",
        "user" => "alice",
        "status" => "running",
        "type" => "v3",
        "branch" => "main",
        "path" => workspace_path
      })
    )
  end

  defp restore(k, nil), do: Application.delete_env(:dev_ide, k)
  defp restore(k, v), do: Application.put_env(:dev_ide, k, v)
end
